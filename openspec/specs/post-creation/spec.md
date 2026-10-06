# post-creation Specification

## Purpose
Provides web interface for creating Instagram posts with AI-powered caption generation. Users can select photos, generate persona-aware captions using remote AI (Gemma3:27b via Ollama), and publish immediately or schedule for later. Integrates with personas, clusters, and the scheduling system to maintain brand voice consistency while avoiding repetitive phrases.
## Requirements
### Requirement: Photo Selection Interface
The system SHALL provide a web interface for browsing and selecting unposted photos for post creation.

#### Scenario: Browse unposted photos
- **WHEN** user navigates to post creation
- **THEN** display a grid of unposted photos
- **AND** show photo preview, persona, and cluster information

#### Scenario: Filter by persona
- **WHEN** user selects a persona filter
- **THEN** show only photos for that persona
- **AND** maintain unposted filter status

#### Scenario: Filter by cluster
- **WHEN** user selects a cluster filter
- **THEN** show only photos in that cluster
- **AND** display cluster name and theme

#### Scenario: Select photo for posting
- **WHEN** user clicks "Create Post" on a photo
- **THEN** navigate to post creation form with photo pre-selected
- **AND** display photo preview with metadata

### Requirement: Post Creation Form
The system SHALL provide a form for creating Instagram posts with caption and scheduling options.

#### Scenario: Display post form with photo
- **WHEN** user accesses post creation form with selected photo
- **THEN** show photo preview with cluster and persona info
- **AND** show empty caption textarea
- **AND** show empty hashtags input
- **AND** show scheduling options

#### Scenario: Manual caption entry
- **WHEN** user types in caption textarea
- **THEN** show character count
- **AND** validate maximum length
- **AND** enable submit button when valid

#### Scenario: Manual hashtag entry
- **WHEN** user enters hashtags
- **THEN** validate hashtag format
- **AND** show count of hashtags
- **AND** warn if exceeding recommended limit

#### Scenario: Schedule for later
- **WHEN** user selects "Schedule" option
- **THEN** show datetime picker
- **AND** default to next optimal posting time
- **AND** create draft post with scheduled_at timestamp

#### Scenario: Post immediately
- **WHEN** user selects "Post Now" option
- **THEN** execute SchedulePost command chain
- **AND** show posting progress
- **AND** redirect to success page with Instagram link

### Requirement: AI Caption Suggestion
The system SHALL generate caption suggestions using Gemma3:27b model with persona-specific context.

#### Scenario: Request AI suggestion
- **WHEN** user clicks "Get AI Suggestions" button
- **THEN** show loading indicator
- **AND** send photo and persona context to caption generator
- **AND** prefill textarea with generated caption
- **AND** store suggestion metadata

#### Scenario: Regenerate suggestion
- **WHEN** user clicks "Regenerate" after receiving suggestion
- **THEN** generate a new variation
- **AND** replace textarea content with new suggestion
- **AND** maintain previous suggestions in history

#### Scenario: Caption generation with persona context
- **WHEN** generating caption
- **THEN** include persona voice and tone configuration
- **AND** include cluster theme and description
- **AND** include photo detected objects
- **AND** include content pillar alignment
- **AND** avoid phrases from recent 20 posts

### Requirement: Caption Generation Service
The system SHALL use Gemma3:27b via Ollama to generate persona-specific captions.

#### Scenario: Build generation prompt
- **WHEN** building prompt for AI model
- **THEN** include system prompt defining Instagram caption writer role
- **AND** include persona caption_config JSON
- **AND** include persona hashtag_strategy JSON
- **AND** include photo analysis with detected objects
- **AND** include cluster theme and context
- **AND** include list of phrases to avoid

#### Scenario: Generate caption via Ollama
- **WHEN** calling Ollama API
- **THEN** use Gemma3:27b model
- **AND** send structured prompt with context
- **AND** receive caption text
- **AND** validate response format

#### Scenario: Process generated caption
- **WHEN** caption is generated
- **THEN** validate length constraints
- **AND** ensure Instagram compliance (no banned words)
- **AND** format for readability
- **AND** return caption with metadata

#### Scenario: Handle Ollama unavailable
- **WHEN** Ollama service is not running
- **THEN** show user-friendly error message
- **AND** suggest manual caption entry
- **AND** log error for debugging

### Requirement: Context Building for Caption Generation
The system SHALL extract rich context from photo, persona, and cluster data for AI prompting.

#### Scenario: Extract photo context
- **WHEN** building context for caption generation
- **THEN** include detected objects/labels from photo analysis
- **AND** include image metadata (dimensions, colors)
- **AND** include any existing descriptions

#### Scenario: Extract cluster context
- **WHEN** photo belongs to a cluster
- **THEN** include cluster name and theme
- **AND** include pillar alignment
- **AND** include cluster AI prompt/description

#### Scenario: Extract persona context
- **WHEN** building persona context
- **THEN** include caption_config (voice, tone, style)
- **AND** include hashtag_strategy
- **AND** include recent posting patterns

#### Scenario: Build repetition avoidance list
- **WHEN** building avoid-phrases list
- **THEN** fetch last 20 captions for persona
- **AND** extract common phrases (3+ words)
- **AND** identify overused words
- **AND** include in prompt as phrases to avoid

### Requirement: Ollama Client Integration
The system SHALL integrate with the remote Ollama service for AI inference. The endpoint is a configuration constant (`AI::OllamaClient::ENDPOINT` / `tc_ops.py CAPTION_ENDPOINT`), overridable via the `TC_CAPTION_ENDPOINT` env var for the probe.

Note 2026-09-29: the caption Ollama moved from 192.168.86.137 (max395) to 192.168.86.49 (game, the 4090 box) per operator directive; same NFS model store.

#### Scenario: Initialize Ollama client
- **WHEN** caption generation is requested
- **THEN** connect to the configured Ollama API endpoint
- **AND** verify Gemma3:27b model is available
- **AND** configure timeout for model loading (60+ seconds on first call)
- **AND** configure retry settings

#### Scenario: Send generation request
- **WHEN** sending prompt to Ollama
- **THEN** format request with model name and prompt
- **AND** set appropriate temperature for creativity
- **AND** handle streaming or complete responses
- **AND** parse response JSON

#### Scenario: Handle first-time model loading
- **WHEN** Ollama loads model for first time
- **THEN** show extended loading indicator (may take 30-60 seconds)
- **AND** set timeout to 90 seconds minimum
- **AND** inform user about initial load delay

#### Scenario: Handle generation timeout
- **WHEN** Ollama request exceeds timeout
- **THEN** cancel request gracefully
- **AND** return timeout error with helpful message
- **AND** log performance metrics

### Requirement: Post Preview and Metadata Display
The system SHALL display relevant photo and context metadata during post creation.

#### Scenario: Show photo preview
- **WHEN** viewing post creation form
- **THEN** display selected photo at appropriate size
- **AND** show photo filename and date
- **AND** show image dimensions

#### Scenario: Show context metadata
- **WHEN** viewing post creation form
- **THEN** display persona name and configuration summary
- **AND** display cluster name and theme
- **AND** display detected objects from photo analysis
- **AND** display content pillar if assigned

#### Scenario: Show posting statistics
- **WHEN** viewing post creation form
- **THEN** show count of recent posts for persona
- **AND** show last posting time
- **AND** show suggested optimal posting time
- **AND** show hashtag usage patterns

### Requirement: Form Validation and Error Handling
The system SHALL validate post creation inputs and handle errors gracefully.

#### Scenario: Validate required fields
- **WHEN** submitting post form
- **THEN** ensure photo is selected
- **AND** ensure persona is assigned
- **AND** ensure caption is not empty
- **AND** show field-specific error messages

#### Scenario: Validate caption length
- **WHEN** caption exceeds Instagram limit
- **THEN** show error message with character count
- **AND** prevent form submission
- **AND** highlight textarea with error styling

#### Scenario: Handle posting failure
- **WHEN** Instagram API returns error
- **THEN** show specific error message
- **AND** preserve form data
- **AND** offer retry option
- **AND** log error details

