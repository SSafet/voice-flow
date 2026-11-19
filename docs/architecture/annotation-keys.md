# Annotate mode key map

Escape commits a pending annotation text note, then exits annotate mode; it
stays the panic button while the agent is acting. Annotate mode
(`AnnotationOverlay`, `swift/Annotation.swift`) is keyboard-driven so the
mouse stays on the thing being marked: tools P draw · H highlight · L line ·
A arrow · R rectangle · C circle · N number stamp · T text · E eraser (Shift
constrains lines to 45°, rect→square, ellipse→circle); colours 1–6 (red,
amber, green, blue, magenta, white); one size dial S/M/L (`[` / `]`) that
sets pen width, highlighter width, shape stroke, badge diameter, and text
size together; ⌘Z / ⇧⌘Z undo/redo handled by the canvas itself (the Edit
menu only reaches it when the app is active), ⌫ undoes the last mark, ⌘⌫
clears and is itself undoable. The toolbar is a draggable HUD strip with the
key printed under each control; while editing, an amber frame outlines each
display and a ring at the cursor previews the active colour and width. A
note being written sits in an opaque box (`AnnotationTextChrome`): drag it
by the header, resize it by the corner handle, A− / A+ or ⌘[ / ⌘] walk a
text-size ladder from 8 to 48 pt (the dial's S/M/L = 10/16/28), ✓ or Escape
commits; the box is see-through with a white line. Notes read on top of
anything through one of two backings (`AnnotationTextStyle`, per note,
sticky like colour and size, persisted): the default **halo** is a soft
blurred shadow in the contrast colour (white, dark for white text) drawn by
`AnnotationTextLayoutManager` under every glyph — a hard outline is not an
option because below ~14 pt any visible stroke fills the one-pixel gaps in
and between letters — and **plate** is a dark rounded plate behind the
paragraph for the busiest backgrounds. Switch with the header's Aa button,
⌘B while typing, or B on the canvas. The live editor and the committed
renderer share the layout manager and the same inset, so a note does not
shift on commit. Annotation text editors own
isolated undo managers that are cleared before detaching; canvas Undo/Redo
routes to live text while typing and to completed marks otherwise. Marks,
in-flight strokes, and text drafts save atomically to `annotations.json` on
change and restore as click-through marks on launch. Clear discards drafts too.
