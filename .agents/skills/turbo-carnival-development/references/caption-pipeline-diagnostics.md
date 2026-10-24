# Caption-pipeline failure diagnostics (turbo-carnival)

Purpose: distinguish B2/S3 (blob download), AI-provider (Gemini/Ollama), and
Instagram-token failures in the caption/post pipeline — quickly, with probes.

## Where captions actually get generated

- Photo has attached image → `CaptionGeneration::VisionGenerator` → **Ollama** (primary `gemma3:27b`, fallback `gemma3:4b`; no API key). Endpoint is `AI::OllamaClient::ENDPOINT` / tc_ops `CAPTION_ENDPOINT` (env override `TC_CAPTION_ENDPOINT`) — currently the game box `192.168.86.49:11434` (moved off max395 `192.168.86.137`; same NFS model store). See SKILL.md "Caption Ollama — hosting, endpoint, probe".
- No attached image / fallback → `CaptionGeneration::Generator` → **Gemini** (`GEMINI_API_KEY`).

Both paths decode the photo FIRST: `VisionGenerator#encode_image` calls `@photo.image.download` (ActiveStorage), which for this app is **Backblaze B2 via S3** (see `config/storage.yml` `b2:` service).

## The "key '....' is not valid" trap

Symptom (seen with `Growth::CadenceEngine` and `chain_test`):
```
Caption generation failed: The key '00437451bb92cd0000000000e' is not valid
```
This is `Aws::S3::Errors::InvalidAccessKeyId` — the **B2 access key** is rejected, NOT Gemini. The Vision path does not call Gemini at all; you can confirm the photo blob download raises while Ollama is healthy.

Repro of the isolation (runner script, `tmp/`):
```ruby
photo = ContentPillars::Photo.find(153)
puts photo.image.attached?                      # true
begin
  bytes = photo.image.download
  puts "download ok: #{bytes.bytesize}"          # never reached
rescue => e
  puts "DOWNLOAD ERROR: #{e.class}: #{e.message[0, 200]}"  # Aws::S3::Errors::InvalidAccessKeyId
end
```

## B2 credentials: where they come from

- `.env` → `B2_ACCESS_KEY_ID`, `B2_APPLICATION_KEY` (dotenv loads these into ENV).
- `config/credentials/development.yml.enc` → `b2: access_key_id / application_key` (the storage.yml `b2:` service interpolates `Rails.application.credentials.dig(:b2, ...)`).
- Both must agree; storage service resolves from the credentials interpolation, and ActiveStorage uses the service. Check what actually resolves at runtime:
```ruby
puts ENV.fetch('B2_ACCESS_KEY_ID', nil)&.length
puts Rails.application.credentials.dig(:b2, :access_key_id).to_s[0,8]
```

## Probing B2 independently of the app

```ruby
require 'aws-sdk-s3'
c = Aws::S3::Client.new(region: 'us-west-004',
                        endpoint: 'https://s3.us-west-004.backblazeb2.com',
                        access_key_id: ENV.fetch('B2_ACCESS_KEY_ID', nil),
                        secret_access_key: ENV.fetch('B2_APPLICATION_KEY', nil))
begin
  r = c.list_objects_v2(bucket: 'fluffy-train-development', max_keys: 2)
  puts "LIST OK: #{r.contents.count}"
rescue => e
  puts "LIST FAIL: #{e.message[0, 120]}"
end
```
Bucket is `fluffy-train-<env>`; endpoint `s3.us-west-004.backblazeb2.com`. If LIST fails with the same key error, the key is revoked (not a code bug).

- The same dead B2 key was duplicated across eidolon / tsort / fluffy-train / image_embed / turbo-carnival `.env` files — check all if one is invalid. Fix = new application key with read access to the bucket (optionally public-read bucket so `GeneratePublicPhotoUrl` works for IG posting).

## Ollama reachability (independent of B2)

```ruby
load 'lib/ai/ollama_client.rb' unless defined?(AI::OllamaClient)
c = AI::OllamaClient.new(model: 'gemma3:27b')
puts c.model_available?          # true when the model is on the box
puts c.list_models.dig('models', 0, 'name')
```
NOTE: `model_available?` swallows Faraday errors and returns false if unreachable — if false, verify the endpoint via plain Faraday `GET /api/tags` to distinguish "model missing" from "server down".

Quick up/down + resident-models check without a Ruby/HTTP stack: `python3 bin/tc_ops.py caption-endpoint` (scanner-safe; prints `up (<url>); resident: <models>` or `down (...)`). The old host (192.168.86.137) answers nothing — connection refused there is expected, not a fault.

## Instagram Graph token expiry

Symptom (from `Growth::MetricsCollector` decision log):
```
API Error: 400 - {"error" => {"message" => "Error validating access token: Session has expired on Sun, 26-Jul-26 ...", "type" => "OAuthException", "code" => 190, "error_subcode" => 463}}
```
- Long-lived Graph token lives in `credentials:instagram:access_token` + `config.storage.yml`-style config (`packs/scheduling/app/clients/instagram/client.rb` reads `Rails.application.credentials.dig(:instagram, ...)`).
- Expired token is non-fatal by design for the harness: `MetricsCollector` degrades to a `skip_data` decision and the loop continues.
- Refresh via Meta Developer portal / Graph Explorer; the token is scoped to the IG business account `account_id`.

## Quick triage matrix

| Failure message | Likely cause | First action |
|---|---|---|
| `The key '...' is not valid` | B2/S3 access key revoked | Check B2 (download / probe list_objects) |
| `401/400` HTTP with `error_subcode 463` `OAuthException` | IG long-lived token expired | Refresh token in credentials |
| `Cannot connect to Ollama at ...` | Ollama down / endpoint unreachable | Verify `/api/tags` on 11434 |
| `No response text from Ollama` | model not loaded / timeout | Check model_available? / retry |