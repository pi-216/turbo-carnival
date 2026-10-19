# Instagram Scheduling Setup

> **Status:** UNREVIEWED — predates the 2026-10 rebuild

## Overview

The scheduling pack enables automated posting to Instagram through the Instagram Graph API. Posts can be scheduled for immediate posting or queued for automated posting via cron jobs.

## How It Works

### Immediate Posting Flow
1. Create post record (draft)
2. Generate public URL for photo
3. Create Instagram media container
4. Publish container to Instagram
5. Update post with Instagram ID (scheduled status)

If any step fails, the entire chain rolls back automatically.

### Scheduled Posting Flow
1. Create draft post with `scheduled_at` timestamp
2. Hourly cron job checks for posts due
3. Posts are processed through the same flow as immediate posting
4. Status updated to `posted` or `failed`

## Setup

### 1. Instagram Credentials

You need an Instagram Business Account connected to a Facebook Page. Get credentials from the Facebook Developer console:

- `app_id` - Facebook App ID
- `app_secret` - Facebook App Secret
- `access_token` - Long-lived User Access Token
- `account_id` - Instagram Business Account ID

Add to Rails credentials:
```bash
bin/rails credentials:edit
```

```yaml
instagram:
  app_id: "your_app_id"
  app_secret: "your_app_secret"
  access_token: "your_token"
  account_id: "your_account_id"
```

### 2. Cron Job Setup

Add to crontab (`crontab -e`):
```
0 * * * * /home/tim/source/activity/turbo-carnival/bin/scheduled_posting.sh
```

This runs every hour at minute 0 (e.g., 1:00, 2:00, 3:00).

Logs are written to `log/scheduled_posting.log`.

### 3. Photo Requirements

Photos must:
- Have an attached image via ActiveStorage
- Be in the `photos` table (Clustering::Photo model)
- Have a publicly accessible URL

The system uses ActiveStorage to generate public URLs for posting to Instagram.

## Usage Examples

### Schedule Immediate Post
```ruby
photo = Clustering::Photo.find(3)
persona = Persona.find(3)

result = Scheduling::SchedulePost.call!(
  photo: photo,
  persona: persona,
  caption: "Beautiful sunset 🌅 #nature #photography"
)

if result.success?
  post = result.post
  puts "Posted to Instagram! ID: #{post.provider_post_id}"
else
  puts "Failed: #{result.errors}"
end
```

### Schedule for Later
```ruby
Scheduling::Post.create!(
  photo_id: 3,
  persona_id: 3,
  caption: "Morning coffee ☕ #coffeelover",
  scheduled_at: 12.hours.from_now,
  status: 'draft'
)
```

### Check Scheduled Posts
```ruby
# Posts ready to publish now
Scheduling::Post.where(status: 'draft')
  .where('scheduled_at <= ?', Time.current)

# Next scheduled post
Scheduling::Post.where(status: 'draft')
  .where('scheduled_at > ?', Time.current)
  .order(:scheduled_at)
  .first
```

### Manual Posting
```bash
# Run the scheduled posting task
bundle exec rails scheduling:post_scheduled

# Or use the shell script (same as cron)
./bin/scheduled_posting.sh
```

## Monitoring

### Check Logs
```bash
tail -f log/scheduled_posting.log
```

### Check Post Status
```ruby
# Recently posted
Scheduling::Post.posted.order(posted_at: :desc).limit(10)

# Failed posts
Scheduling::Post.where(status: 'failed')

# Upcoming scheduled posts
Scheduling::Post.where(status: 'draft')
  .where('scheduled_at > ?', Time.current)
  .order(:scheduled_at)
```

## Troubleshooting

### Instagram API Errors

If posting fails, check:
1. Access token is still valid (they expire)
2. Photo URL is publicly accessible
3. Caption doesn't exceed Instagram limits
4. Image meets Instagram requirements (aspect ratio, size)

### Rollback Behavior

The command chain automatically rolls back on failure:
- Draft post is deleted
- Instagram container (if created) remains but isn't published
- Error details are logged

### Manual Cleanup

If posts get stuck:
```ruby
# Reset stuck posts
Scheduling::Post.where(status: 'posting').update_all(status: 'failed')
```

## Migration from fluffy-train

To switch from fluffy-train to turbo-carnival:

1. Ensure credentials are copied to turbo-carnival
2. Test manual posting first
3. Update crontab to point to new script
4. Monitor first few hourly runs
5. Disable fluffy-train cron job

Old cron:
```
0 * * * * /home/tim/source/activity/fluffy-train/bin/scheduled_posting.sh
```

New cron:
```
0 * * * * /home/tim/source/activity/turbo-carnival/bin/scheduled_posting.sh
```
