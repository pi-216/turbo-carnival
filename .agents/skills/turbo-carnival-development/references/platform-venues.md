# Platform venues for a synthetic adult persona

Decision table for *where* a photoreal, fully-synthetic adult persona may publish.
Verified by research 2026-10; **re-verify before building** (see the rule at the bottom).

## The question

"Find a platform that explicitly allows sexual, AI-generated NSFW content" is a
narrower question than it looks. Three separate things are regulated independently:
(a) whether a *fully synthetic* persona may hold an account at all, (b) whether
*photorealistic* AI adult imagery is allowed, and (c) whether the operator may remain
anonymous. Most platforms allow one or two and prohibit the third.

## Decision table

| Platform | Fully synthetic persona | Photoreal AI adult | Verdict |
|---|---|---|---|
| **Fanvue** | Yes — AI creators are a recognised, verified category | Yes, must be labelled | **Payload venue** |
| **X / Twitter** | Yes — adult + AI-generated explicitly permitted | Yes, with dual labelling | Candidate discovery surface |
| OnlyFans | **No** — fully synthetic personas get accounts terminated | Own likeness only | Out |
| Fansly | Non-photoreal virtual entities only | **No** — photoreal AI banned outright; an AI label does not make it permissible | Out (photoreal) |
| Patreon | Illustrated/animated only | Only with a real adult's documented consent | Out |

## Constraints that shape the architecture

- **Fanvue**: prominent disclosure required (bio, caption, or watermark); **public
discovery media must stay SFW** — profile picture, banner and intro video included;
no under-18 cues, phrasing that bites is "or *seems* underage"; the operator must
complete real-identity verification; explicit content allowed when labelled and
paywalled. Fanvue also prohibits AI used to *deceive* (presenting a synthetic persona
as a real person a fan might meet).
- **X**: adult content permitted when labelled and not placed in "highly visible"
areas — **profile picture and banner are explicitly prohibited**. AI-generated adult
content needs a *separate* AI-disclosure label on top of the sensitivity tier. X also
prohibits manufactured identities used deceptively, aggressive automation, and
repeated link-only promotion — funnel mechanics must be clean.
- **Universal floor** (every venue): CSAM, non-consensual intimate imagery, and
non-consent are prohibited everywhere. This is a legal floor, not a taste preference.

## Architectural consequences

The platform rules and the risk posture **converge**: both demand a SFW public
surface with the explicit material behind a paywall. Design to that and compliance
and safety are the same architecture.

1. **Two venues, blast-radius isolated.** SFW discovery venue + explicit payload
   venue, different personas, separate credentials (email, phone, payment, logins).
2. **No cross-linking.** Different handles, no shared watermark, no shared
   link-in-bio, no shared bio text, no shared browser/app session. Isolation must be
   architectural — enforced by structure, not by remembering to be careful.
3. **Neutral interstitial** between the SFW venue and the explicit one: direct links
   to an explicit paywall run into sexual-solicitation rules on the SFW side.
4. **Separate config rows / job namespaces** per persona so no shared code path can
   leak state, credentials, or assets between venues.
5. **Adult aesthetic is load-bearing twice over** — every venue independently bans
   minor cues, so an explicit age gate is a business requirement as well as a legal
   one.

## Rule: a policy summary is not the policy

Re-read the platform's **own** help-centre/community-guidelines page immediately
before building anything that depends on it, and record what you read. Third-party
creator-guide articles disagree with each other and go stale, and the policies here
change on a scale of months. One genuinely unresolved item from the last review:
whether AI-driven chat/DM automation is still permitted on Fanvue — sources
conflicted, so confirm from the primary source before designing engagement automation.
