# vale-ai-tells

A [Vale](https://vale.sh) package for detecting linguistic patterns commonly associated with AI-generated prose. Based on 2024-2025 research into vocabulary fingerprints, structural patterns, and rhetorical tells.

<!-- vale proselint.Annotations = NO -->
> [!NOTE]
> The author created this package to help clean up AI-assisted technical documentation, not to disguise AI-generated content as human-written.
<!-- vale proselint.Annotations = YES -->

## Installation

Add the package to your `.vale.ini`:

```ini
StylesPath = styles
MinAlertLevel = suggestion

Packages = https://github.com/tbhb/vale-ai-tells/releases/download/v0.1.0/ai-tells.zip

[*.md]
BasedOnStyles = ai-tells
```

Then run:

```bash
vale sync
```

## Rules included

This package contains 11 rule files covering different categories of AI tells:

<!-- vale off -->

### Warning level (strong indicators)

| Rule | Description |
|------|-------------|
| `OverusedVocabulary` | Words with documented AI overuse: "delve," "tapestry," "multifaceted," "leverage," "foster," etc. |
| `OpeningCliches` | AI-style openings: "In today's rapidly evolving landscape," "In the realm of," etc. |
| `SycophancyMarkers` | Flattering phrases: "Great question," "I'm happy to help," "You make an excellent point," etc. |
| `AICompoundPhrases` | Compound phrases: "rich tapestry," "intricate interplay," "paradigm shift," etc. |

### Suggestion level (patterns AI overuses)

| Rule | Description |
|------|-------------|
| `HedgingPhrases` | Compulsive hedging: "It's important to note that," "Generally speaking," etc. |
| `ConclusionMarkers` | Formulaic conclusions: "In conclusion," "Ultimately," "At the end of the day," etc. |
| `FormalTransitions` | Formal transitions: "Moreover," "Furthermore," "Additionally," etc. |
| `FalseBalance` | Evasive "both sides" language: "both sides present valid points," etc. |
| `EmDashUsage` | Em-dashes which AI uses excessively |
| `FillerPhrases` | Padding: "a wide range of," "in order to," "due to the fact that," etc. |
| `FormalRegister` | Overly formal vocabulary: "utilize," "facilitate," "commence," etc. |

<!-- vale on -->

## Customization

Disable specific rules:

```ini
[*.md]
BasedOnStyles = ai-tells
ai-tells.FormalTransitions = NO
ai-tells.EmDashUsage = NO
```

Change severity levels:

```ini
[*.md]
BasedOnStyles = ai-tells
ai-tells.HedgingPhrases = error
```

## Limitations

This package catches lexical and phrasal patterns. It can't detect:

- Sentence-length uniformity, or burstiness
- Perplexity scores
- Paragraph-length patterns
- Semantic analysis
- Model-specific stylometric signatures

For comprehensive detection, combine this package with statistical analysis tools.

## Sources

Based on research including:

- [Delving into ChatGPT usage in academic writing through excess vocabulary](https://arxiv.org/abs/2406.07016) (arXiv, 2024)
- [Distinguishing academic science writing from humans or ChatGPT with over 99% accuracy](https://pmc.ncbi.nlm.nih.gov/articles/PMC10328544/) (PMC, 2023)
- [Wikipedia: Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing)
- Practitioner guides from 2024 and 2025

## License

MIT
