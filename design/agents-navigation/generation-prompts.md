# Agents navigation image-generation prompts

All three images were generated with the built-in ImageGen tool. The two user-supplied Voice Flow screenshots were passed as visual references, not edit targets.

## Variation A — Mission Control

```text
Use case: ui-mockup
Asset type: polished high-fidelity portrait product UI mockup for a native macOS app
Primary request: Design a new “Mission Control” Overview screen for the Voice Flow Agents tab. This is a new interface design, not an edit or collage of the references. The root screen must answer immediately: what needs me, what is running, and where can I go.
Input images: Image 1 and Image 2 are STYLE AND PRODUCT-CHROME REFERENCES ONLY. Preserve their compact warm-dark native macOS Voice Flow visual language and recognizable top chrome, but create an entirely new layout below it.
Canvas: portrait app panel, approximately the same proportions as the references, full-frame front-on screenshot, no device mockup, no surrounding desktop.
Style/medium: shippable native macOS AppKit UI, restrained and precise, dark warm charcoal, soft sand text, muted bronze secondary text, amber-gold accent, hairline borders, subtle hover-depth surfaces, rounded corners, crisp SF-style symbols. Dense but calm. No glassmorphism, no neon, no gradients, no futuristic concept art.
Top chrome: keep “Voice Flow” at upper left and the existing small icon toolbar at upper right. Under it keep the top segmented control with “Inbox 9”, “Agents 3” selected in amber-gold, and the music-note icon at right.
Agents navigation: directly below, show a compact second-level navigation bar with “Overview” selected, then “Assistants”, “Automations”, “Conversations”, plus a small search icon with “⌘K”. At the right of the Overview title row, place a compact amber “+ Create” button.
Main hierarchy: not a vertical feed. Use a deliberate bento mission-control layout with generous separation and strong alignment.
Top bento row:
- Left card titled exactly “Needs you” with an amber count badge “2”. Show two compact actionable rows: “Claude #1” with supporting text “Approval needed · file access” and a small “Review” action; “Screenwatch” with supporting text “Daily review ready” and a small “Open” action.
- Right card titled exactly “Running now” with count “2”. Show two live rows with tiny amber pulse dots: “Voice Flow release” with supporting text “Testing signed app · 12m”; “P001 research” with supporting text “Gathering sources · 4m”. Include a subtle “View all” link.
Second area titled exactly “Go to” as three equal destination tiles in one horizontal row:
1) “Assistants” with large count “6”, supporting text “People and capabilities”, a simple assistant-wave icon, and a tiny circular plus.
2) “Automations” with large count “3”, supporting text “1 scheduled next”, a simple clock-arrow icon, and a tiny circular plus.
3) “Conversations” with large count “9”, supporting text “2 unread”, a simple dialogue icon, and a tiny circular plus.
Destination tiles are prominent navigational surfaces, not nested cards.
Bottom area: one compact wide strip titled “Up next” with “Screenwatch review · Today, 21:37” and a warm outlined “Open automation” action. This is subordinate to the bento above.
Interaction cues: one-click rows and tiles, clear selected states, understated chevrons, precise spacing, no sidebar.
Typography: readable native macOS sans serif, hierarchy through size and weight rather than excessive boxes. Render the specified labels verbatim and avoid extra copy.
Color palette: near-black #171714 background; warm charcoal #24221E surfaces; off-white #F3E9DB primary text; bronze-gray #9A8770 secondary; amber-gold #DDAE52 selected fills and status; very subtle #403A32 borders.
Constraints: keep all content within the panel; no clipping; no overlapping; no duplicate cards; no excessive rows; no phone bezel; no watermark; no logo redesign; no sidebar; no bottom tab bar; no bright colors besides amber. Make it look implementable in the existing Voice Flow app.
```

## Variation B — Persistent Rail

```text
Use case: ui-mockup
Asset type: polished high-fidelity portrait product UI concept for the macOS Voice Flow app
Primary request: Generate a brand-new redesigned Agents tab built around a PERSISTENT LOCAL NAVIGATOR / RAIL. This is not an edit of either reference screenshot. The design must feel fully shippable, native, calm, and compact. Navigation is by user intent, never runtime or implementation object.
Input images: Image 1 is a visual-reference-only screenshot for the existing Voice Flow window, warm-dark palette, typography, top chrome, outer panel shape, and density. Image 2 is a visual-reference-only screenshot for the same app and its list-row treatment. Do not copy the current vertically mixed Agents content.
Canvas and framing: one straight-on portrait screenshot of the entire Voice Flow floating panel, approximately 790 x 1050 px, with the full rounded window visible and the tiny three-dot pill centered below it as in the references. No device mockup, no desktop background, no perspective, no hands.
Existing chrome to preserve: rounded dark macOS panel; header text "Voice Flow" at top left; the same sparse line icons at top right; thin divider; existing rounded segmented switch below with "Inbox 9", selected amber "Agents 3", and a music-note icon. Keep this top region highly faithful to the references.
New Agents content architecture below the segmented switch:
- Split the content into a slim persistent left navigation rail about 30% width and a wider right workspace about 70% width. The rail remains visually present; do not use horizontal tabs, cards, or a hidden hamburger menu.
- Rail background is only subtly different from the main surface and separated by one hairline vertical rule.
- Rail destinations, exact text: selected "Now" with a small amber count "2"; "Assistants" with count "4"; "Automations" with count "3"; "Conversations" with count "7". Each is a compact icon-plus-label row. Selected Now uses a slim amber leading bar and a very soft amber-tinted row, not a large filled button.
- At the bottom of the rail, separated by whitespace, show two one-click text actions exactly: "+ Assistant" and "+ Automation". These are contextual creation shortcuts, understated and easy to reach.
- Right workspace header: large label "Now"; smaller sublabel "Monday · August 3"; small search icon and overflow icon aligned right.
- This root must answer WHAT NEEDS ME and WHAT IS RUNNING using dense master-list rows, never cards.
- First section heading exact text "NEEDS YOU" and amber count "2". Row one: amber warning-ring icon; title "Approve release retry"; metadata "Voice Flow release · 12m"; a compact right-aligned amber text action "Review". Row two: amber numbered circle "5"; title "Claude #1 needs a decision"; metadata "Conversation · 23m"; right-aligned amber action "Open".
- Second section heading exact text "RUNNING" and count "2". Row one: small spinning/radar glyph; title "Screenwatch daily review"; metadata "Automation · 62%"; thin restrained amber progress line beneath; right edge "8m". Row two: small pulsing-dot glyph; title "Voice Flow regression sweep"; metadata "Automation · 3 of 7 checks"; right edge "Live".
- Third section heading exact text "RECENT". Two quieter rows: "FLORA organized today’s tickets" with metadata "Conversation · 18:42"; "Model picker fix completed" with metadata "Automation · 17:56".
- Use generous but efficient spacing and subtle one-pixel dividers. Main content is a calm status list, not stacked cards.
Interaction cues in the static image: the rail is obviously persistent; rows look clickable; urgency is signaled only by amber icon/action, not by red or giant banners; running status is visible at a glance; destinations and urgent rows are each one click away from Now.
Style/medium: native AppKit/macOS UI screenshot, high-fidelity product design, precise vector-like controls, crisp typography.
Color palette: near-black warm charcoal #171714 surface; slightly lighter #22211E selection/rows; warm ivory #F1E9DD primary text; muted taupe #9B8A78 secondary text; restrained honey amber #D9A94F accents. Match the two reference screenshots.
Typography: compact native macOS sans-serif similar to SF Pro, clear hierarchy, no oversized display text.
Constraints: Render all listed text verbatim and correctly spelled. Keep all content safely inside the rounded panel. Preserve the existing top chrome and three-dot bottom pill. Make the new rail/main split immediately legible. No runtime labels such as Codex, OpenCode, model, provider, server, job, or session as navigation categories.
Avoid: dashboard cards, cards-inside-cards, horizontal navigation for Assistants/Automations/Conversations, giant metrics, bright gradients, glassmorphism, neon, blue accent, white background, mobile phone frame, browser chrome, sidebar wider than 32%, tiny illegible body text, clipped rows, duplicated labels, warped icons, extra controls, watermark.
```

## Variation C — Assistant Spaces

```text
Use case: ui-mockup
Asset type: polished high-fidelity portrait product-design mockup for the Voice Flow native macOS app
Primary request: Design a completely new Agents-tab root screen called the assistant-centric "Spaces" variation. The user navigates by intent, not implementation. The root must instantly answer: what needs me, what is running, and where can I go. Each persistent assistant is visually presented as a workspace/room containing its conversations, automations, memory/skills, and current work. External MCP sessions remain directly reachable. The result must look genuinely shippable in hand-built AppKit, not concept art.
Input images: Image 1 is visual reference only for the existing Voice Flow panel proportions, top chrome, palette, typography, border, spacing density, and icons. Image 2 is visual reference only for the existing Voice Flow visual language and current session-row styling. Do not use either as an edit target.
Canvas and framing: one straight-on 790×1100 portrait screenshot of a borderless rounded floating macOS panel, filling the canvas like the references. No device mockup, no perspective, no hands, no desktop scene.
Preserve the existing top chrome: rounded charcoal-black panel with thin warm-gray border; header title "Voice Flow" at upper left; the same five restrained line icons at upper right; thin divider; the existing wide tab switcher beneath it with "Inbox 9", selected amber "Agents 3", and the music-note destination on the right.
New Agents navigation immediately below the existing switcher: a single quiet text navigation rail with four one-click destinations, exactly "Now", "Assistants 3", "Automations 5", "Sessions 7". "Now" is selected with a short amber underline, not a filled pill. This rail is visually distinct from the main Inbox/Agents switcher.
Root content hierarchy:
1. Section label "NEEDS YOU" with amber count "2". Under it, one full-width high-priority row: small amber ring/wave icon; title "FLORA needs your answer"; preview "Add these 6 actions to Notion?"; trailing compact amber text button "Reply". Beside or immediately beneath it, a visually paired but clearly separate "RUNNING 2" area with two extremely compact live rows: "Voice Flow · release QA" with "2 of 4 checks", and "Pantrella · retention review" with "8m". Use tiny amber activity dots/progress, never large progress bars.
2. Section header "ASSISTANT SPACES" with a small contextual "+ New" action aligned right.
3. A distinctive assistant-space map, not a flat feed and not generic cards-inside-cards. Show three workspace/room surfaces:
- A wide primary FLORA space spanning the content width. Title "FLORA"; subtitle "Personal ops & knowledge"; status line "Waiting for you · 1"; one current-work line "Today’s transcript review"; and a shallow divided doorway strip with exactly "Chats 4", "Automations 2", "Skills 6", plus a small chevron to enter the whole space.
- Two compact spaces side by side beneath: "Voice Flow" / "Build & ship" / "QA running"; doorway labels "Chats 7", "Automations 3", "Skills 4". And "Pantrella" / "Product & retention" / "Last active 18m"; doorway labels "Chats 3", "Automations 1", "Skills 3".
The space surfaces should feel like open rooms: one contiguous warm-charcoal field each, subtle inset boundary, one amber status edge or dot, and thin internal doorway dividers. Avoid nested floating cards.
4. A final full-width low-profile row labeled "EXTERNAL SESSIONS" with "3 connected · 1 unread" and a trailing chevron, making MCP sessions one click away.
Interaction affordances visible in the still: rows and room surfaces have subtle hover-ready contours; amber means selected, live, waiting, or primary action; muted taupe means metadata; cream means readable content. Creation is contextual: only "+ New" beside Assistant Spaces appears on this root. No global giant plus button. No "new assistant" or "new automation" feed rows.
Style/medium: native AppKit macOS UI, screenshot fidelity, restrained editorial spacing, SF Pro-like typography, SF Symbols-like thin icons, warm dark Voice Flow aesthetic from the references.
Color palette: nearly black #171715 background, warm charcoal #24221f surfaces, cream #f2eadf primary text, taupe #a79783 secondary text, amber/gold #d9aa4d accent, subtle warm gray borders.
Composition: spacious but information-dense, strong grouping, no visual clutter, no sidebar, no three-column dashboard, no conventional SaaS look. Keep all content within the rounded panel and preserve generous edge padding.
Text: render all quoted labels verbatim and legibly. Do not invent extra copy.
Avoid: bright white, blue or purple accents, gradients, glassmorphism, neon, drop-shadow-heavy cards, oversized type, playful illustrations, robots, avatars, browser chrome, iPhone frame, generic web dashboard, excessive pills, repeated header labels, tiny illegible text, decorative graphs, or content outside the panel.
```

## Mission Control v2 — Focused operations

```text
Use case: ui-mockup
Asset type: refined high-fidelity native macOS product UI mockup for Voice Flow

Primary request: Generate a brand-new second iteration of the chosen Voice Flow “Mission Control” Agents tab. Redesign what the root shows and how it uses space. It must be an operational surface, not an inventory dashboard: at a glance, show only what currently needs the user and what is provably running. Make the information more readable and useful per pixel than the prior Mission Control image.

Input images:
- Image 1: visual reference only for the real Voice Flow 400×520pt panel proportions, exact top chrome, palette, typography, density, and warm-dark style.
- Image 2: visual reference only for current row density, stable session treatment, and existing product language.
- Image 3: the chosen Mission Control direction, but only as a conceptual reference. Deliberately remove its space-heavy page title, giant Create button, Go to tiles, inventory counts, Up next strip, duplicated destination navigation, and oversized cards. Do not edit or collage any reference.

Canvas and framing: one straight-on portrait screenshot of the entire rounded Voice Flow floating panel at the same proportions as Images 1 and 2, including the tiny three-dot pill centered immediately below. No device frame, no desktop, no perspective.

Preserve existing top chrome faithfully: “Voice Flow” at top left; the same five restrained line icons at upper right; thin divider; the existing rounded selector with “Inbox 9”, selected flat amber “Agents 3”, and the music-note icon.

New compact local navigation directly below the primary selector:
- one quiet 34pt-high text rail, no surrounding card
- exact labels left to right: selected “Now” with a small amber badge “2”; “Assistants”; “Automations”; “Threads” with a small amber badge “3”; one trailing search icon
- selection is cream text with a short 2pt amber underline
- no inventory counts on Assistants or Automations
- no page heading, no Create button, no overflow menu, no second copy of the destinations

Root body: use two full-width grouped operational zones with strong separation and readable full-width rows. Do not use two narrow columns.

Zone 1:
- section header exactly “NEEDS YOU” with amber count “2”
- one contiguous subtle warm-charcoal group with two rows and a single hairline divider
- row 1: leading amber question-bubble icon; primary exact text “Add these 6 actions to Notion?”; secondary exact text “FLORA · asked 4m ago”; compact trailing amber navigation verb “Reply”
- row 2: leading amber raised-hand approval icon; primary exact text “Allow file access for release QA”; secondary exact text “Voice Flow automation · 12m ago”; compact trailing amber navigation verb “Review”
- the full rows look clickable; Reply and Review navigate to evidence/context, not immediate side effects

Zone 2:
- section header exactly “RUNNING NOW” with amber count “2”
- one contiguous subtle warm-charcoal group with two rows and a single hairline divider
- row 1: leading animated-looking amber dotted-circle glyph; primary exact text “Voice Flow release QA”; secondary exact text “FLORA automation · 2 of 4 checks · 12m”; include one thin restrained 50%-filled amber progress line beneath the metadata; no visible Stop button
- row 2: leading small amber pulse/radar glyph; primary exact text “Screenwatch daily review”; secondary exact text “FLORA automation · summarizing 18 captures · 8m”; no progress bar when progress is indeterminate
- the full rows look clickable and open live context

Information and spacing rules:
- use the real narrow panel intelligently: 12–16pt outer inset, 10–12pt section gap, 52–60pt rows, compact 11–13pt native text hierarchy
- every row answers: what, owner, state/progress, and time
- titles and metadata remain readable; avoid truncation in the shown sample
- use only two large grouped surfaces, not separate cards per item
- disciplined empty space below the running zone is acceptable; do not fill it with low-value information
- amber means user action or live activity; cream title; taupe metadata; muted vermilion is reserved for failures but no failure is shown here
- solid fills only, no gradients or glow

Style/medium: shippable hand-built AppKit UI, exact Voice Flow warm-dark visual language, crisp SF Pro-like typography and SF Symbols-like line icons, subtle 1px warm borders, native restraint.

Color palette: near-black #1C1A18 background, warm charcoal #24211E grouped surfaces, cream #F0E6D6 primary text, taupe #A79783 metadata, amber #D4A853 accent, low-contrast warm border.

Constraints: render all quoted text verbatim and correctly spelled; keep everything inside the rounded panel; preserve the original top chrome; preserve touch/click target clarity; no watermark.

Avoid: the “Overview” heading, destination tiles, total assistant/automation counts, recent history, completed work, scheduled/up-next work, inventory descriptions, giant metrics, bento cards, two-column content, large buttons, repeated navigation, nested cards, status pills, blue/purple/green, glassmorphism, gradients, neon, charts, decorative illustrations, tiny illegible type, browser chrome, phone frame.
```

The generated draft was then edited with ImageGen to make the Mission Control root content-height-adaptive, preserving all UI above the panel bottom. The final asset was deterministically cropped to the resulting panel bounds after ImageGen retained its original canvas aspect ratio.
