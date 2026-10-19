# Caption Generation Pack

This pack provides AI-powered caption generation for Instagram posts using Gemma3:27b via Ollama.

## Features

- Persona-specific voice and tone configuration
- Context-aware caption generation (cluster themes, image descriptions)  
- Repetition avoidance across recent captions
- Instagram compliance validation
- Rich prompt building with persona/cluster/pillar context

## Components

- `CaptionGeneration::Generator` - Main generation service
- `CaptionGeneration::PromptBuilder` - AI prompt construction with context
- `CaptionGeneration::ContextBuilder` - Context extraction from photo/cluster
- `CaptionGeneration::RepetitionChecker` - Phrase deduplication
- `CaptionGeneration::PostProcessor` - Validation and formatting

## Dependencies

- `packs/personas` - Persona model with caption_config
- `packs/clustering` - Photo and Cluster models
- `packs/scheduling` - Post history for repetition checking
- `lib/ai/ollama_client` - Gemma3:27b inference

## Usage

```ruby
result = CaptionGeneration::Generator.generate(
  photo: photo,
  persona: persona,
  cluster: cluster
)

if result.success?
  puts result.text
  puts result.metadata
end
```
