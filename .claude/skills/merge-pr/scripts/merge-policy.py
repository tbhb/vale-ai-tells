# pylint: disable=duplicate-code
# The generator copies this helper verbatim into both harness packages.
# cspell:words surrogateescape alnum cntrl xdigit
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Inspect pinned Git changes and APM ownership; never execute repository settings."""

import json
import re
import shutil
import string
import subprocess
import sys
from operator import itemgetter
from pathlib import Path, PurePosixPath
from typing import NoReturn, cast

LockRecord = dict[str, str | list[str] | None]
Review = dict[str, object]
GIT = shutil.which("git")
if GIT is None:
    sys.exit("git is required")


def fail(message: str) -> NoReturn:
    """Reject unreadable policy without repeating private configuration values."""
    raise ValueError(message)


def git(*args: str) -> bytes:
    """Read exact objects without diff drivers or text conversion."""
    return subprocess.check_output([GIT, "-c", "core.quotePath=false", *args])  # noqa: S603 # Fixed Git operations with separate arguments.


def blob(ref: str, path: str) -> bytes:
    """Absent files are optional; other Git errors must propagate."""
    entries = git("ls-tree", ref, "--", path)
    if not entries:
        return b""
    if not entries.startswith(b"100644 ") and not entries.startswith(b"100755 "):
        fail("Policy input must be a regular Git blob")
    return git("cat-file", "blob", f"{ref}:{path}")


def regex(value: str, key: str = "policy") -> re.Pattern[str]:
    """Require explicit patterns, including ^$ for an intentionally empty set."""
    if not value:
        fail(f"Policy pattern {key} must not be empty")
    # Preserve the C-locale POSIX character classes used by existing ERE settings.
    classes = {
        "alnum": string.ascii_letters + string.digits,
        "alpha": string.ascii_letters,
        "blank": " \t",
        "cntrl": "".join(chr(code) for code in [*range(32), 127]),
        "digit": string.digits,
        "graph": string.ascii_letters + string.digits + string.punctuation,
        "lower": string.ascii_lowercase,
        "print": string.ascii_letters + string.digits + string.punctuation + " ",
        "punct": string.punctuation,
        "space": string.whitespace,
        "upper": string.ascii_uppercase,
        "xdigit": string.hexdigits,
    }
    for name, characters in classes.items():
        value = value.replace("[:" + name + ":]", re.escape(characters))
    return re.compile(value)


def deployment_path(value: object) -> str:
    """Only project-relative deployed paths may exempt a scan."""
    if not isinstance(value, str) or not value:
        fail("Invalid APM deployed path")
    path = PurePosixPath(value)
    if not path.parts or path.is_absolute() or ".." in path.parts:
        fail("Invalid APM deployed path")
    return value.removeprefix("./").rstrip("/")


def lock_scalar(value: str) -> str | None:
    """Read the scalar forms emitted in an APM lockfile."""
    value = value.strip()
    if not value:
        fail("Invalid APM lockfile scalar")
    if value in {"null", "~"}:
        return None
    if value.startswith('"'):
        parsed = json.loads(value)
        if not isinstance(parsed, str):
            fail("Invalid APM lockfile scalar")
        return parsed
    if value.startswith("'"):
        if not value[1:].endswith("'"):
            fail("Invalid APM lockfile scalar")
        return value[1:-1].replace("''", "'")
    return value


def lock_list(value: str) -> list[str]:
    """Read the simple flow sequences APM uses for deployed paths."""
    if value == "[]":
        return []
    if not value.startswith("[") or not value.endswith("]"):
        fail("Invalid APM lockfile list")
    items = value[1:-1].split(",")
    parsed = [lock_scalar(item) for item in items]
    if any(item is None for item in parsed):
        fail("Invalid APM lockfile list")
    return [item for item in parsed if item is not None]


def lock_records(text: str, name: str, *, required_section: bool) -> list[str]:
    """Split one top-level generated APM sequence into record bodies."""
    headers = list(re.finditer(rf"(?m)^{name}:(.*)$", text))
    if not headers:
        if required_section:
            fail("Invalid APM lockfile dependencies")
        return []
    if len(headers) != 1:
        fail("Duplicate APM lockfile section")
    header = headers[0]
    suffix = header.group(1).strip()
    if suffix == "[]":
        return []
    if suffix:
        fail("Invalid APM lockfile section")
    start = header.end() + 1
    following = re.search(r"(?m)^[A-Za-z_][\w-]*:", text[start:])
    end = start + following.start() if following else len(text)
    body = text[start:end].strip("\n")
    if not body:
        return []
    if not body.startswith("- "):
        fail("Invalid APM lockfile record")
    return body[2:].split("\n- ")


def lock_record(text: str, keys: tuple[str, ...]) -> LockRecord:
    """Read selected scalar and path-list fields from one record."""
    text = "  " + text
    record: LockRecord = {}
    for key in keys:
        matches = list(re.finditer(rf"(?m)^  {key}:(?: (.*))?$", text))
        if len(matches) > 1:
            fail("Duplicate APM lockfile field")
        if not matches:
            continue
        value = (matches[0].group(1) or "").strip()
        if value.startswith("["):
            record[key] = lock_list(value)
        elif value:
            record[key] = lock_scalar(value)
        elif key == "deployed_files":
            tail = text[matches[0].end() :]
            items = re.match(r"(?m)((?:\n  - .*)*)", tail)
            values = re.findall(r"(?m)^  - (.*)$", items.group(1) if items else "")
            parsed = [lock_scalar(item) for item in values]
            if any(item is None for item in parsed):
                fail("Invalid APM lockfile list")
            record[key] = [item for item in parsed if item is not None]
        else:
            fail("Invalid APM lockfile scalar")
    return record


def parse_lock(data: bytes) -> tuple[list[LockRecord], list[LockRecord]]:
    """Parse only the generated lockfile records used for ownership."""
    text = data.decode("utf-8")
    dependencies = [
        lock_record(
            record,
            ("repo_url", "source", "local_path", "virtual_path", "deployed_files"),
        )
        for record in lock_records(text, "dependencies", required_section=True)
    ]
    deployments = [
        lock_record(record, ("kind", "value", "active_owner"))
        for record in lock_records(text, "deployments", required_section=False)
    ]
    return dependencies, deployments


def lock_text(record: LockRecord, key: str, default: str = "") -> str:
    """Read an optional string field with a typed default."""
    value = record.get(key, default)
    if not isinstance(value, str):
        fail("Invalid APM lockfile field")
    return value


def owned_remotely(base: str) -> dict[str, bool]:
    """Use base ownership and honor active owners where APM records them."""
    data = blob(base, "apm.lock.yaml")
    if not data:
        return {}
    dependencies, records = parse_lock(data)
    owned = {}
    identities = {}
    for dep in dependencies:
        repository = lock_text(dep, "repo_url")
        local_path = lock_text(dep, "local_path")
        local = bool(
            lock_text(dep, "source") == "local"
            or local_path
            or repository.startswith("_local/")
        )
        virtual_path = lock_text(dep, "virtual_path")
        identity = local_path or (
            repository + "/" + virtual_path if virtual_path else repository
        )
        identities[identity] = not local
        paths = dep.get("deployed_files", [])
        if not isinstance(paths, list):
            fail("Invalid APM deployed_files")
        for value in paths:
            path = deployment_path(value)
            # Without active ownership metadata, keep local overlaps in scope.
            owned[path] = owned.get(path, True) and not local
    for record in records:
        if lock_text(record, "kind") != "project-relative":
            continue
        owner = lock_text(record, "active_owner")
        if owner not in identities:
            fail("Unknown APM active owner")
        owned[deployment_path(lock_text(record, "value"))] = identities[owner]
    return owned


def remote_path(path: str, owned: dict[str, bool]) -> bool:
    """The most specific deployed owner wins; never exempt package sources."""
    matching = [root for root in owned if path == root or path.startswith(root + "/")]
    return bool(matching) and owned[max(matching, key=len)]


COMMENT = re.compile(r"^\s*(?:#|//|/\*|\*|<!--|;)")
EXCLUSION = re.compile(
    r"^\s*[-{,]?\s*[\"']?(?:exclude(?:s)?|extend-exclude|ignore|ignored|"
    r"ignore[-_]patterns|disable(?:d)?|skip|allow(?:ed)?|"
    r"allow[-_]list)[\"']?\s*[:=]",
    re.IGNORECASE,
)
REMOVED_GATE = re.compile(
    r"^\s*(?:-\s*id\s*:|(?:-\s*)?[\"']?mise run (?:lint|check|test)|"
    r"(?:lint|check|test)[\w-]*\s*=)"
)
LOCK_CHECKSUM = re.compile(r"^\s*checksum\s*=")


def vendored_nolint(
    path: str, base: str, paths: list[str], comment: str, markers: re.Pattern[str]
) -> bool:
    """Exempt only `nolint` upstream wrote in a Go file the diff re-vendors."""
    return (
        path.startswith("vendor/")
        and path.endswith(".go")
        and "vendor/modules.txt" in paths
        and bool(git("ls-tree", base, "--", "vendor/modules.txt"))
        and all(match.group(0) == "nolint" for match in markers.finditer(comment))
    )


PIN_WORKFLOW_PATH = re.compile(r"^\.github/workflows/[^/]+\.ya?ml$")
PIN_APM = re.compile(
    r'^(\s*-\s*(?P<q>["\']?)tbhb-dev/devtools'
    r"(?:/packages/agents/(?:common|claude|codex|agy))?#)"
    r"v[0-9]+\.[0-9]+\.[0-9]+"
    r"((?P=q)(?:\s+#.*|\s*))$"
)
PIN_MISE = re.compile(
    r'^("go:github\.com/tbhb-dev/devtools/cmd/'
    r'(?:guard-markdown|commit-lint|gh-post|agentrepo)"\s*=\s*)'
    r'"v[0-9]+\.[0-9]+\.[0-9]+"(\s*(?:#.*)?)$'
)
PIN_WORKFLOW = re.compile(
    r"^(\s*(?:-\s+)?uses:\s*tbhb-dev/devtools/[^@\s]+@)"
    r"[0-9a-f]{7,40}"
    r"(\s*#\s*)v[0-9]+\.[0-9]+\.[0-9]+(\s.*|)$"
)
PIN_TOMBI = re.compile(r"^( *#.*\btbhb-dev/devtools +)v[0-9]+\.[0-9]+\.[0-9]+(.*)$")
PIN_RENOVATE = re.compile(
    r'^(\s*"github>tbhb-dev/devtools//\.github/[^/"]+\.json5#)'
    r"(?:[0-9a-f]{7,40}|v[0-9]+\.[0-9]+\.[0-9]+)"
    r'(",?\s*//\s*)v[0-9]+\.[0-9]+\.[0-9]+(\s.*|)$'
)
PIN_VENDIR_CONTEXT = re.compile(
    r"^( *)(- +)?url: +https://github\.com/tbhb-dev/devtools(?: +#.*| *)$"
)
PIN_VENDIR = re.compile(r"^( *ref:\s*)v[0-9]+\.[0-9]+\.[0-9]+(\s*)$")
PIN_PRECOMMIT_CONTEXT = re.compile(
    r"^( *)(- +)?repo: +https://github\.com/tbhb-dev/devtools(?: +#.*| *)$"
)
PIN_PRECOMMIT = re.compile(
    r"^( *rev:\s*)[0-9a-f]{7,40}(\s+#\s*frozen:\s*)v[0-9]+\.[0-9]+\.[0-9]+(\s*)$"
)
PIN_PATTERNS: dict[str, tuple[re.Pattern[str], str]] = {
    "apm.yml": (PIN_APM, r"\g<1><VERSION>\g<3>"),
    "mise.toml": (PIN_MISE, r'\g<1>"<VERSION>"\g<2>'),
    "tombi.toml": (PIN_TOMBI, r"\g<1><VERSION>\g<2>"),
    ".github/renovate.json5": (
        PIN_RENOVATE,
        r"\g<1><REF>\g<2><VERSION>\g<3>",
    ),
}
PIN_CONTEXT_PATTERNS: dict[str, tuple[re.Pattern[str], re.Pattern[str], str]] = {
    "vendir.yml": (PIN_VENDIR_CONTEXT, PIN_VENDIR, r"\g<1><VERSION>\g<2>"),
    ".pre-commit-config.yaml": (
        PIN_PRECOMMIT_CONTEXT,
        PIN_PRECOMMIT,
        r"\g<1><SHA>\g<2><VERSION>\g<3>",
    ),
}


def pin_skeleton(path: str, line: str) -> str | None:
    """Normalize a single-line devtools pin to its version-independent skeleton."""
    spec = PIN_PATTERNS.get(path)
    if spec is None and PIN_WORKFLOW_PATH.fullmatch(path):
        spec = (PIN_WORKFLOW, r"\g<1><SHA>\g<2><VERSION>\g<3>")
    if spec is None:
        return None
    match = spec[0].fullmatch(line)
    return match.expand(spec[1]) if match else None


def pin_block(path: str, context: str, minus: list[str], plus: list[str]) -> bool:
    """Accept only in-place devtools version pin replacements in pins.toml form."""
    # These separators can introduce YAML content inside a physical diff line.
    if any(
        re.search(r"[\r\v\f\x1c-\x1e\x85\u2028\u2029]", line)
        for line in [context, *minus, *plus]
    ):
        return False
    if not minus or len(minus) != len(plus):
        return False
    if path in PIN_CONTEXT_PATTERNS:
        ctx_re, line_re, template = PIN_CONTEXT_PATTERNS[path]
        ctx_match = ctx_re.fullmatch(context)
        if len(minus) != 1 or ctx_match is None:
            return False
        # A sequence marker contributes to the repository key's column.
        column = len(ctx_match[1]) + len(ctx_match[2] or "")
        if any(len(line) - len(line.lstrip(" ")) != column for line in [*minus, *plus]):
            return False
        old_match = line_re.fullmatch(minus[0])
        new_match = line_re.fullmatch(plus[0])
        return bool(
            old_match
            and new_match
            and old_match.expand(template) == new_match.expand(template)
        )
    old_skeletons = [pin_skeleton(path, line) for line in minus]
    new_skeletons = [pin_skeleton(path, line) for line in plus]
    return all(old_skeletons) and old_skeletons == new_skeletons


def diff_blocks(diff: str) -> list[tuple[str, list[str], list[str]]] | None:
    """Extract (preceding_context, removed_lines, added_lines) for each edit block."""
    blocks: list[tuple[str, list[str], list[str]]] = []
    context = ""
    in_hunk = False
    minus: list[str] = []
    plus: list[str] = []
    for line in diff.removesuffix("\n").split("\n"):
        if not in_hunk and line.startswith(
            ("diff --git ", "index ", "--- a/", "+++ b/")
        ):
            continue
        if line.startswith(("@@ ", " ")):
            in_hunk = True
            if minus or plus:
                blocks.append((context, [*minus], [*plus]))
                minus.clear()
                plus.clear()
            context = "" if line.startswith("@@ ") else line[1:]
        elif line.startswith("-") and not plus:
            minus.append(line[1:])
        elif line.startswith("+"):
            plus.append(line[1:])
        else:
            return None
    if minus or plus:
        blocks.append((context, minus, plus))
    return blocks


def pin_only_diff(path: str, diff: str) -> bool:
    """Return whether a file's diff edits only devtools pins in pins.toml form."""
    blocks = diff_blocks(diff)
    return bool(blocks) and all(
        pin_block(path, context, minus, plus) for context, minus, plus in blocks
    )


def inline_comment(text: str) -> str:
    """Do not interpret a marker inside a quoted value as a suppression."""
    quote = ""
    escaped = False
    for index, char in enumerate(text):
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif quote:
            if char == quote:
                quote = ""
        elif char in "\"'`":
            quote = char
        elif (
            index
            and text[index - 1].isspace()
            and (char == "#" or text[index:].startswith(("//", "<!--")))
        ):
            return text[index:].lower()
    return ""


def constitutional_paths(base: str) -> re.Pattern[str]:
    """Read constitutional_paths from .agents/agent-skills.conf at the pinned base."""
    data = blob(base, ".agents/agent-skills.conf").decode("utf-8")
    for line in data.split("\n"):
        if line.lstrip(" \t").startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if sep and key.strip(" \t") == "constitutional_paths":
            return regex(value.strip(" \t"), "constitutional_paths")
    return regex("^$", "constitutional_paths")


def scan_loosening(
    path: str,
    diff: str,
    patterns: tuple[re.Pattern[str], re.Pattern[str]],
    base: str,
    paths: list[str],
) -> list[list[str]]:
    """Return suppression, exclusion, and removed-gate findings from a file diff."""
    markers, configs = patterns
    findings: list[list[str]] = []
    lines = [
        line
        for line in diff.split("\n")
        if not line.startswith(("+++", "---")) and line.startswith(("+", "-"))
    ]
    # Re-recording every removed checksum replaces them; it removes no gate.
    replaced = PurePosixPath(path).name == "mise.lock" and sum(
        line.startswith("+") and bool(LOCK_CHECKSUM.match(line[1:])) for line in lines
    ) >= sum(
        line.startswith("-") and bool(LOCK_CHECKSUM.match(line[1:])) for line in lines
    )
    for line in lines:
        text = line[1:]
        if COMMENT.match(text):
            continue
        comment = inline_comment(text)
        if line.startswith("+") and (
            (
                markers.search(comment)
                and not vendored_nolint(path, base, paths, comment, markers)
            )
            or (configs.search(path) and EXCLUSION.search(text))
        ):
            findings.append([path, "adds a suppression or exclusion"])
        elif (
            line.startswith("-")
            and configs.search(path)
            and REMOVED_GATE.search(text)
            and not (replaced and LOCK_CHECKSUM.match(text))
        ):
            findings.append([path, "removes a hook or gate"])
    return findings


def inspect(base: str, head: str, config: dict[str, str]) -> dict[str, object]:
    """Return reasons needing an owner and the owner paths for reporting."""
    golden, markers, configs, owners = [
        regex(config.get(key, ""), key)
        for key in (
            "golden_paths",
            "loosening_markers",
            "gate_config_paths",
            "owner_paths",
        )
    ]
    constitutional = constitutional_paths(base)
    # Validate cleanup policy before any irreversible write as well.
    regex(config.get("disposable_ignored", ""), "disposable_ignored")
    mergebase = git("merge-base", base, head).decode().strip()
    paths = [
        p.decode("utf-8", "surrogateescape")
        for p in git(
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--name-only",
            "-z",
            mergebase,
            head,
        ).split(b"\0")
        if p
    ]
    if not paths:
        fail("Pinned change has no paths")
    owned = owned_remotely(base)
    findings: list[list[str]] = []
    non_pin_findings = False
    owner_paths = [path for path in paths if owners.search(path)]
    for path in paths:
        diff = git(
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--text",
            "--unified=1",
            mergebase,
            head,
            "--",
            path,
        ).decode("utf-8", "surrogateescape")
        pin_only = pin_only_diff(path, diff)
        if constitutional.search(path):
            findings.append([path, "changes a constitutional file"])
            non_pin_findings = non_pin_findings or not pin_only
        if remote_path(path, owned):
            continue
        if golden.search(path):
            findings.append([path, "changes a golden file"])
            non_pin_findings = non_pin_findings or not pin_only
        loosening = scan_loosening(path, diff, (markers, configs), base, paths)
        if loosening:
            findings.extend(loosening)
            non_pin_findings = True
    return {
        "findings": findings if non_pin_findings else [],
        "owner_paths": owner_paths,
    }


def states_no(body: str, head: str) -> bool:
    """Accept only the literal statement immediately after a plain review header."""
    body = body.replace("\r\n", "\n")
    if not re.fullmatch(r"[\x20-\x7e\t\n]*", body):
        return False
    if len(re.findall(r"loosens\s*:", body, re.IGNORECASE)) != 1:
        return False
    match = re.match(
        r"\AReviewed head: ([0-9a-f]{40}|`[0-9a-f]{40}`)\n\n*"
        r"(?:Model: [A-Za-z0-9. _-]+\n\n*)?"
        r"Loosens: no(?:\n(?:\n|\Z)|\Z)",
        body,
    )
    return bool(match and match.group(1).strip("`") == head)


def evaluate(
    policy: dict[str, object], reviewer: str, head: str, view: dict[str, object]
) -> dict[str, object]:
    """Only the required App's current approval can waive golden findings."""
    reviews = cast("list[Review]", view["reviews"])
    if not isinstance(reviews, list):
        fail("Invalid reviews")
    decisive: list[Review] = [
        review
        for review in reviews
        if cast("dict[str, str]", review.get("author", {})).get("login") == reviewer
        and review.get("state") in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}
    ]
    decisive.sort(key=itemgetter("submittedAt"))
    review: Review = decisive[-1] if decisive else {}
    body = review.get("body")
    findings = policy["findings"]
    if not isinstance(findings, list):
        fail("Invalid findings")
    waived = bool(
        findings
        and all(finding[1] == "changes a golden file" for finding in findings)
        and reviewer
        and view.get("headRefOid") == head
        and review.get("state") == "APPROVED"
        and cast("dict[str, str]", review.get("commit", {})).get("oid") == head
        and cast("dict[str, str]", review.get("author", {})).get("__typename") == "Bot"
        and "lastEditedAt" in review
        and review["lastEditedAt"] is None
        and review.get("submittedAt")
        and sum(item.get("submittedAt") == review["submittedAt"] for item in decisive)
        == 1
        and isinstance(body, str)
        and states_no(body, head)
    )
    return policy | {
        "owner_required": bool(findings) and not waived,
        "owner_rule": "App review states Loosens: no" if waived else "owner approval",
    }


def ref_matches(pattern: str, branch: str, default: str) -> bool:
    """Ruleset single stars cannot cross a slash; double stars can."""
    if pattern == "~ALL":
        return True
    if pattern == "~DEFAULT_BRANCH":
        return branch == default
    escaped = (
        re.escape(pattern)
        .replace(r"\*\*", ".*")
        .replace(r"\*", "[^/]*")
        .replace(r"\?", "[^/]")
    )
    return re.fullmatch(escaped, "refs/heads/" + branch) is not None


def string_list(value: object, label: str) -> list[str]:
    """Narrow one JSON list to strings."""
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        fail(f"Invalid {label}")
    return value


def ruleset_rules(data: object, branch: str, default: str) -> list[object]:
    """Return active rules where a ruleset applies to the target branch."""
    if not isinstance(data, dict):
        fail("Invalid ruleset")
    if data.get("target") != "branch" or data.get("enforcement") != "active":
        return []
    conditions_value = data.get("conditions")
    if not isinstance(conditions_value, dict):
        fail("Invalid ruleset conditions")
    conditions: dict[str, object] = conditions_value
    refs_value = conditions.get("ref_name")
    if not isinstance(refs_value, dict):
        fail("Invalid ruleset ref names")
    refs: dict[str, object] = refs_value
    included = string_list(refs.get("include", []), "ruleset includes")
    excluded = string_list(refs.get("exclude", []), "ruleset excludes")
    rules = data.get("rules")
    if not isinstance(rules, list):
        fail("Invalid ruleset rules")
    if any(ref_matches(p, branch, default) for p in included) and not any(
        ref_matches(p, branch, default) for p in excluded
    ):
        return rules
    return []


def required_names(rules: list[object]) -> set[str]:
    """Validate required-check rules and collect their contexts."""
    names: set[str] = set()
    for rule in rules:
        if not isinstance(rule, dict):
            fail("Invalid required check rule")
        if rule.get("type") != "required_status_checks":
            continue
        parameters = rule.get("parameters")
        if not isinstance(parameters, dict):
            fail("Invalid required check parameters")
        checks = parameters.get("required_status_checks")
        if not isinstance(checks, list):
            fail("Invalid required checks")
        for check in checks:
            if not isinstance(check, dict) or not isinstance(check.get("context"), str):
                fail("Invalid required check")
            names.add(check["context"])
    return names


def required(base: str, branch: str, default: str, directory: str, live: str) -> None:
    """Union live applied rules and active ruleset files at the pinned base."""
    if (
        not directory
        or PurePosixPath(directory).is_absolute()
        or ".." in PurePosixPath(directory).parts
    ):
        fail("ruleset_dir must be inside the repository")
    parsed_rules: object = json.loads(live)
    if not isinstance(parsed_rules, list):
        fail("Invalid applied rules")
    rules: list[object] = parsed_rules
    for name in git("ls-tree", "-r", "--name-only", "-z", base, "--", directory).split(
        b"\0"
    ):
        if not name.endswith(b".json"):
            continue
        rules.extend(
            ruleset_rules(json.loads(blob(base, name.decode())), branch, default)
        )
    names = required_names(rules)
    if not names or any(not name for name in names):
        fail("No required checks are known for the base")
    print("\n".join(sorted(names)))


def valuable_ignored(worktree: Path, pattern: re.Pattern[str]) -> bool:
    """Keep ignored configuration unless the repository marks it disposable."""
    ignored = git(
        "-C",
        str(worktree),
        "ls-files",
        "--others",
        "--ignored",
        "--exclude-standard",
        "-z",
    )
    return any(
        not pattern.search(path.decode("utf-8", "surrogateescape"))
        for path in ignored.split(b"\0")
        if path
    )


def cleanup(base: str, branch: str, expected: str, merge: str, disposable: str) -> None:
    """Keep current, dirty, non-agent, and ignored-file worktrees intact."""
    pattern = regex(disposable)
    rows = (
        git("worktree", "list", "--porcelain", "-z")
        .decode("utf-8", "surrogateescape")
        .split("\0\0")
    )
    worktrees = [
        dict(field.split(" ", 1) for field in row.split("\0") if " " in field)
        for row in rows
        if row
    ]
    main = Path(worktrees[0]["worktree"]).resolve()
    current = Path.cwd().resolve()

    def run(*args: str) -> bool:
        result = subprocess.run([GIT, *args], check=False)  # noqa: S603 # Fixed cleanup operations; no shell.
        return result.returncode == 0

    main_branch = subprocess.run(  # noqa: S603 # Fixed Git branch lookup.
        [GIT, "-C", str(main), "symbolic-ref", "--short", "HEAD"],
        capture_output=True,
        check=False,
    )
    if (
        main_branch.returncode == 0
        and main_branch.stdout.decode().strip() == base
        and not git("-C", str(main), "status", "--porcelain", "--untracked-files=no")
    ):
        if valuable_ignored(main, pattern):
            print("Main checkout holds valuable ignored files; retained")
        else:
            run("-C", str(main), "merge", "--ff-only", merge)
    ref = "refs/heads/" + branch
    tip = subprocess.run(  # noqa: S603 # Fixed Git ref lookup.
        [GIT, "rev-parse", "--verify", ref], capture_output=True, check=False
    )
    if tip.returncode or tip.stdout.decode().strip() != expected:
        print("Local branch absent or moved; retained")
        return
    for row in worktrees:
        if row.get("branch") != ref:
            continue
        worktree = Path(row["worktree"]).resolve()
        allowed = main / ".claude" / "worktrees"
        if (
            worktree == current
            or worktree in current.parents
            or allowed not in worktree.parents
        ):
            print("Current or non-agent worktree retained")
            return
        if git("-C", str(worktree), "status", "--porcelain", "--untracked-files=all"):
            print("Dirty worktree retained")
            return
        if valuable_ignored(worktree, pattern):
            print("Worktree with valuable ignored files retained")
            return
        if not run("worktree", "remove", str(worktree)):
            print("Worktree removal refused; branch retained")
            return
    # Keep native checked-out-branch and unmerged-work protections.
    if not run("branch", "-d", "--", branch):
        print("Local branch retained by Git cleanup protections")


def main() -> None:
    """Expose file-oriented interfaces for the shared shell entry points."""
    mode, *args = sys.argv[1:]
    match mode, args:
        case "inspect", [base, head]:
            print(json.dumps(inspect(base, head, json.loads(sys.stdin.read()))))
        case "evaluate", [reviewer, head, view]:
            print(
                json.dumps(
                    evaluate(
                        json.loads(sys.stdin.read()),
                        reviewer,
                        head,
                        json.loads(Path(view).read_text(encoding="utf-8")),
                    )
                )
            )
        case "required", [base, branch, default, directory]:
            required(base, branch, default, directory, sys.stdin.read())
        case "cleanup", [base, branch, expected, merge, disposable]:
            cleanup(base, branch, expected, merge, disposable)
        case _:
            fail("Unknown policy operation or arguments")


if __name__ == "__main__":
    try:
        main()
    except (
        ValueError,
        re.error,
        KeyError,
        TypeError,
        UnicodeDecodeError,
        OSError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"merge policy unreadable: {error}", file=sys.stderr)
        sys.exit(1)
