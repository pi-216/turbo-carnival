# Design notes: scenes/bedroom-front.txt

> **Status:** CURRENT — design notes for the active scene

These notes must NEVER live inside the scene file: tc_render.py sends the raw file text as the prompt.
Design notes for this variant (not part of the prompt text):
  1. "the camera positioned fully in front of her — she faces the lens and is never turned
     away" is an explicit anti-from-behind instruction. The previous scene asked for
     "looking back over her shoulder", which put the rear in frame and produced the
     naked-behind failures.
  2. Seated, frontal, "forearms resting on her thighs, both hands visible" is chosen to give
     the ARM AND HAND inpaint pass (workflow node 86, "Young female arm and hand") an easy,
     unoccluded, symmetric crop. The from-behind pose gave it the opposite: arms at awkward
     angles, partly hidden. "fingers together and clearly separated from each other" is
     aimed at fused/extra finger artefacts.
  3. Wardrobe wording is IDENTICAL to the validated version (chest-covering bib, bare
     shoulders and legs) so this variant isolates setting and pose, not clothing.
  4. "A woman alone" plus the new negative guards (2girls, multiple girls, two women) are the
     two halves of the multi-person fix.
  5. Setting changes kitchen -> bedroom so the pose change is not confounded with repeating
     the same background.
