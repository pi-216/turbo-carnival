# Scheduling Pack

This pack handles Instagram post scheduling and publishing.

## Responsibilities

- Track scheduled posts with `Scheduling::Post` model
- Manage post lifecycle through state machine (draft → scheduled → posting → posted/failed)
- Publish posts to Instagram via Instagram Graph API
- Automate posting through rake tasks

## Components

### Models
- `Scheduling::Post` - Post records with status tracking

### Commands
- `Scheduling::SchedulePost` - Main command chain for scheduling posts
- `Scheduling::Commands::CreatePostRecord` - Create post record
- `Scheduling::Commands::GeneratePublicPhotoUrl` - Generate public URL for photo
- `Scheduling::Commands::SendPostToInstagram` - Post to Instagram API
- `Scheduling::Commands::UpdatePostWithInstagramId` - Update with Instagram ID

### Clients
- `Instagram::Client` - Instagram Graph API client

### Rake Tasks
- `scheduling:post_scheduled` - Post any scheduled posts that are due
- `scheduling:create_scheduled_post` - Create a scheduled post using content strategy

## Dependencies

- `packs/personas` - Persona model
- `packs/clustering` - Photo model and Cluster model

## Usage

### Schedule a post immediately (posts to Instagram right away)
```ruby
result = Scheduling::SchedulePost.call!(
  photo: Clustering::Photo.find(3),
  persona: Persona.find(3),
  caption: "My caption #hashtags"
)

if result.success?
  puts "Posted! Instagram ID: #{result.post.provider_post_id}"
end
```

### Schedule for later (automated posting via cron)
```ruby
post = Scheduling::Post.create!(
  photo_id: 3,
  persona_id: 3,
  caption: "My caption #hashtags",
  scheduled_at: 1.hour.from_now,
  status: 'draft'
)
```

### Run scheduled posting manually
```bash
bundle exec rails scheduling:post_scheduled
```

### Automated posting via cron
Add to crontab (`crontab -e`):
```
0 * * * * /home/tim/source/activity/turbo-carnival/bin/scheduled_posting.sh
```

This runs every hour at the top of the hour and posts any drafts with `scheduled_at` or `optimal_time_calculated` that have been reached.

## Instagram Credentials

Required credentials in `config/credentials/development.yml.enc`:
```yaml
instagram:
  app_id: "your_app_id"
  app_secret: "your_app_secret"
  access_token: "your_long_lived_access_token"
  account_id: "your_instagram_business_account_id"
```

Edit credentials: `bin/rails credentials:edit`

## Post States

Posts flow through these states:
- `draft` - Initial state, ready to be processed
- `scheduled` - Instagram container created, has `provider_post_id`
- `posting` - Currently being posted (transition state)
- `posted` - Successfully posted to Instagram with `posted_at` timestamp
- `failed` - Error occurred during posting

## Database Schema

The `scheduling_posts` table includes:
- Core: `photo_id`, `persona_id`, `caption`, `status`
- Instagram: `provider_post_id`, `posted_at`, `scheduled_at`
- Strategy: `cluster_id`, `strategy_name`, `optimal_time_calculated`, `hashtags`
- Metadata: `caption_metadata` (JSONB for additional context)
