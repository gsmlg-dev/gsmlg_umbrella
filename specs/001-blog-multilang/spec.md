# Feature Specification: Blog Multi-Language Support

**Feature Branch**: `001-blog-multilang`
**Created**: 2026-03-19
**Status**: Draft
**Input**: User description: "read @docs/blog_multi_language.md"

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Read Blog in Preferred Language (Priority: P1)

A visitor arrives at the blog. Their browser is set to Simplified Chinese. They see blog posts displayed in Simplified Chinese — both posts originally written in Chinese and posts written in English (which have been AI-translated). The same URL works for everyone; the language shown adapts to the viewer automatically.

**Why this priority**: This is the core value of the feature — readers see content in their preferred language without any manual action. All other user stories depend on this working correctly.

**Independent Test**: Can be fully tested by loading `/blog` and `/blog/:slug` with different `Accept-Language` headers and verifying the displayed content language matches the requested locale, including fallback to source when no translation is available.

**Acceptance Scenarios**:

1. **Given** a blog post exists in English, **When** a visitor's browser sends `Accept-Language: zh-CN`, **Then** the post is displayed in Simplified Chinese.
2. **Given** a blog post was originally written in Chinese, **When** an English-speaking visitor loads it, **Then** the post is displayed in English.
3. **Given** no translation exists yet for French, **When** a French visitor loads any post, **Then** the post is shown in its original language — no error, no missing content.
4. **Given** a visitor previously selected Japanese via the language switcher, **When** they navigate to a new post, **Then** the post renders in Japanese without re-selecting.

---

### User Story 2 — Switch Language via UI Toggle (Priority: P2)

A visitor reading a post in English notices a language switcher showing all supported languages by their native names. They click "简体中文" and the page reloads in Chinese. Their choice is remembered for all subsequent pages.

**Why this priority**: Some visitors' browser locale differs from their actual preference. The manual override is essential for usability, especially for multilingual readers.

**Independent Test**: Can be tested independently by clicking language options in the switcher, verifying content changes, navigating to another post, and confirming the selection persists.

**Acceptance Scenarios**:

1. **Given** a visitor is reading a post, **When** they select a language from the switcher, **Then** the page refreshes showing content in that language.
2. **Given** a visitor selected Japanese in the language switcher, **When** they navigate to another post, **Then** that post also displays in Japanese without re-selecting.
3. **Given** a translation is still being processed, **When** a visitor selects that language, **Then** the original source content is shown as a fallback (not an error or blank page).
4. **Given** a visitor uses the `?lang=zh-Hans` query parameter, **When** the page loads, **Then** the language switcher reflects this selection and it is persisted for future page views.

---

### User Story 3 — AI-Translated Content is Clearly Indicated (Priority: P2)

A reader viewing a post in a language other than the original sees a subtle "AI translated" indicator. This sets appropriate expectations about content provenance.

**Why this priority**: Transparency about AI-generated content builds reader trust. Without this signal, readers may not understand why phrasing differs from their native idiom.

**Independent Test**: Can be tested by viewing any post in a non-source language and confirming the indicator appears; viewing in the source locale confirms the indicator is absent.

**Acceptance Scenarios**:

1. **Given** a post originally in English is displayed in French, **When** the reader views it, **Then** an "AI translated" indicator is visible.
2. **Given** a post originally in Chinese is displayed in Chinese, **When** the reader views it, **Then** no "AI translated" indicator appears.
3. **Given** no translation exists and the post falls back to its source language, **When** the reader views it, **Then** the indicator is absent (content is original, not translated).
4. **Given** a translation is still being processed, **When** a reader views the post in their preferred language, **Then** a "translation in progress" indicator is shown alongside the source-language fallback content — not an error state.

---

### User Story 4 — New Blog Posts Are Automatically Translated (Priority: P3)

An author publishes a new post in English. Without any manual action, translations into all other supported languages are enqueued and processed automatically. Within a reasonable time, the post becomes available in all supported languages.

**Why this priority**: Automation keeps the translation library current without requiring authors to manage translation manually. This is a background concern once the read path works.

**Independent Test**: Can be tested by creating a post and verifying that after processing, all target languages show translated content and statuses are updated accordingly.

**Acceptance Scenarios**:

1. **Given** a new post is created in English, **When** the post is saved, **Then** translation jobs are automatically queued for all other supported languages.
2. **Given** translations are still processing, **When** a visitor requests one of those languages, **Then** the source content is shown as a fallback.
3. **Given** a post's content is edited, **When** the update is saved, **Then** existing translations are marked outdated and re-translation is automatically triggered.
4. **Given** a translation job fails, **When** the system retries, **Then** the job is retried automatically and eventually marked as permanently failed if it cannot complete after multiple attempts.

---

### User Story 5 — Admin Manages Translation Status (Priority: P3)

An admin views a dashboard showing all blog posts with their translation status per language. They can see which translations are pending, completed, failed, or outdated — and can take corrective action without needing developer involvement.

**Why this priority**: Without admin visibility and control, translation failures are silent and content quality cannot be maintained. This unlocks self-service for the content team.

**Independent Test**: Can be tested by loading the admin translation dashboard, viewing status per post per language, clicking "re-translate" on a failed translation, and confirming a new job is queued.

**Acceptance Scenarios**:

1. **Given** the admin loads the translation dashboard, **When** they view a post, **Then** they see the translation status for each supported language (pending, in-progress, completed, failed, outdated, or source).
2. **Given** a translation has failed, **When** the admin clicks "re-translate", **Then** a new translation job is queued and the status resets to pending.
3. **Given** the admin edits a translation manually, **When** they save it, **Then** the translation is marked completed and is not automatically overwritten by the AI on the next update.
4. **Given** a post's source language was misidentified, **When** the admin corrects the source language, **Then** the change is saved and translations reflect the correct source.

---

### Edge Cases

- What happens when a supported language is later removed from configuration? Existing completed translations remain stored, but the language no longer appears in the switcher or is served to visitors.
- What if a post has no completed translation and its source locale is not the visitor's preference? The source content is always shown — the post is never blank or inaccessible.
- What if the AI translation service is unavailable? Translation jobs retry automatically; readers always see source content as a fallback.
- What if a visitor sends `Accept-Language: zh-CN` but the system recognises only `zh-Hans`? The system maps browser locale variants to supported locales automatically.
- What happens if a visitor switches language on the blog index vs. a detail page? The preference is global to the site, not page-specific.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Each blog post MUST have a designated source locale identifying its original language.
- **FR-002**: The list of supported display languages MUST be controlled by configuration — no code changes or database schema changes are required to add a language.
- **FR-003**: Visitors MUST see blog content in their preferred language, resolved in order: explicit URL parameter → saved preference → browser preference → system default.
- **FR-004**: When a visitor's preferred language differs from a post's source language, the system MUST display a completed translation if available, falling back to source content without error.
- **FR-005**: The system MUST automatically queue translations for all non-source languages when a blog post is created.
- **FR-006**: The system MUST automatically mark existing translations as outdated and queue re-translation when a post's title or body is updated.
- **FR-007**: The system MUST display a visible indicator when content is shown in a translated language rather than the original.
- **FR-007b**: The system MUST display a visible "translation in progress" indicator when a post is shown in its source language because no completed translation exists yet for the visitor's preferred language — distinguishing this state from "this post was originally written in your language".
- **FR-008**: A language switcher MUST appear in the site-wide page footer on all pages, showing all supported languages with their native-language names. The selected language persists globally across the site, not just within the blog section.
- **FR-009**: A visitor's language preference MUST persist across page navigation within the site session.
- **FR-010**: Each translation MUST have a tracked lifecycle status: pending, in-progress, completed, failed, or outdated.
- **FR-011**: Failed translation jobs MUST be retried automatically a limited number of times before being marked permanently failed.
- **FR-012**: Any authenticated admin user MUST be able to view translation status for every post across all supported languages from a single dashboard — no role differentiation within the admin area.
- **FR-013**: Any authenticated admin user MUST be able to manually trigger re-translation for any post or specific language.
- **FR-014**: Any authenticated admin user MUST be able to manually edit a translation, with that edit preserved and not overwritten by automated re-translation.
- **FR-015**: Any authenticated admin user MUST be able to correct a post's source language if it was misidentified.
- **FR-016**: A batch operation MUST exist to queue translations for any post that lacks a completed or in-progress translation for any configured locale. Posts with no translation record for a locale are treated as implicitly pending — this uniformly covers both initial setup and newly added languages without requiring explicit record creation.
- **FR-017**: Blog URL paths MUST remain unchanged — locale is resolved from context (preference, header, parameter), not from the URL structure.

### Key Entities

- **Blog Post**: The canonical piece of content with a source locale, original title, and body text. Always the fallback when no translation is available.
- **Translation**: A version of a post's title and body in a specific non-source language. Has a lifecycle status and can be manually corrected by an admin.
- **Supported Locale**: A language the system is configured to serve. Defined in configuration, not in the database. Adding a locale requires only configuration and a batch translation run.
- **Language Preference**: A visitor's selected display language, persisted across page views within their session.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Visitors always see readable content in their preferred language — zero instances of blank or missing post content due to a missing translation.
- **SC-002**: Translation jobs for all other supported languages are queued within 1 minute of a post being created or updated.
- **SC-003**: Adding a new supported language requires no code changes and no database migrations — only a configuration update and a batch task run.
- **SC-004**: 100% of blog list and detail pages correctly reflect the visitor's resolved locale preference.
- **SC-005**: An admin can determine the translation status of any post in any supported language within 2 navigation steps from the admin area.
- **SC-006**: Manually corrected translations are never overwritten by automated re-translation unless the admin explicitly requests it.
- **SC-007**: All existing completed translations for a post are marked outdated automatically whenever the post's content changes — no manual intervention required.

## Assumptions

- Existing blog posts written in Chinese are all Simplified Chinese (not Traditional); initial source locale classification uses character detection heuristics.
- The system has access to an AI translation service capable of translating blog-length content (title and full body) in a single call. Blog posts are public content — no data residency, GDPR, or provider restrictions apply to sending post content to external AI translation services.
- Simplified Chinese and Traditional Chinese are treated as distinct target languages — neither is a fallback for the other.
- No blog URL paths change as part of this feature; existing bookmarks and external links remain valid.
- The initial supported language set is: English, Simplified Chinese, Traditional Chinese, French, Spanish, German, Italian, and Japanese.
- Translations generated for a language that is later removed from configuration remain in storage but are not displayed to visitors.
- Blog posts are always readable without requiring a translation — the source content is the permanent fallback.

## Clarifications

### Session 2026-03-19

- Q: Which admin users have access to translation management actions (dashboard, re-translate, manual edit, source locale correction)? → A: Any authenticated admin user has full access — no role differentiation within the admin area.
- Q: What is the expected SLA for translation *completion* (not just queuing)? → A: No hard completion SLA; visitors must see a visible "translation in progress" indicator when fallback source content is shown because their preferred translation is still processing.
- Q: Are there data residency, GDPR, or provider constraints on sending blog content to an external AI translation service? → A: No constraints — blog posts are public content and may be sent to any suitable external AI translation provider.
- Q: Where does the language switcher appear — blog pages only, global navigation, or elsewhere? → A: Site-wide page footer on all pages; the language preference is global to the site.
- Q: When a new language is added to configuration, how does the batch task find existing posts that need translation? → A: Posts with no translation record for a configured locale are treated as implicitly pending — the batch task queries for any post missing a completed or in-progress translation for any configured locale.
