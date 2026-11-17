Request from Tyrone: upgrade PhotoCriticViewer scoring and workflow. Read the codebase first (SwiftUI viewer + ../photocritic Python, vision_model.py, config.py, prompts/evaluation_v3.txt, LocalAPI*.swift, export_photo.py). Don't modify or delete my originals or existing results; add a migration, not a wipe.

PROBLEM (real data, 2000 results): scores range only 77-92, mean 80.3, SD 3.1. 60% are exactly 78; the values cluster on 78/82/85/87/88. 100% KEEP, 97% B. Category SD is about 0.5-0.8. The scores are useless for ranking. I want a real spread that separates my portfolio-level frames from average ones and from rejects.

1. CALIBRATED SCORING (biggest priority)
- Single-photo scoring temperature 0-0.2. Optional self-consistency: score N=3 and take the median, with a config flag.
- Rewrite the prompt as evaluation_v4.txt with anchored rubrics for each category: concrete descriptions of 2, 4, 6, 8 and 10. A 10 is rare: publishable in a top magazine. Use 5 as "competent but unremarkable". Use the full 0-10 range and decimals. Tell the model the expected distribution: most frames in a shoot are 4-7 and only about 5% go above 8.5. Require a one-line justification per category, written before its number (reason, then score).
- Compute the overall score, grade and KEEP/MAYBE/REJECT in CODE from the category scores, using configurable weights (e.g. lighting, expression, pose, composition and emotional impact weighted higher). The model no longer picks the grade. Grade thresholds go in config.
- Relative calibration per shoot: also store a percentile within the shoot and within the whole library, plus a z-score. Use the burst/group ranking prompt (ranking_v1) to break ties between near-duplicates. Keep the raw score and the calibrated score in separate fields.
- Store prompt_version, model_id, temperature, and weights with every result.
- Add a re-score command/endpoint that re-scores a sample (e.g. 50 photos across shoots), prints a before/after distribution histogram, and only re-scores the whole library when I confirm.

2. PER-FILE CRITIQUE + QUEUE
- /critique with ids evaluates only those ids, not the whole shoot.
- Queue jobs instead of returning 409. Persist jobs in SQLite so they survive a relaunch, and clean up old finished jobs.

3. PHOTOGRAPHER COACHING REPORT (critique my photography)
- New endpoint GET /report?shoot=&since= and a Dashboard view that aggregate my results into a coaching report: my strongest and weakest categories, trends over time and by shoot, recurring issues pulled from the critique text (most frequent themes), my 10 best and 10 weakest frames with reasons, and 3-5 specific things to practice on my next shoot.
- Current baseline from my data, so you can test against it: my weakest categories are background 6.74, color/tonality 7.17, lighting 7.38, composition 7.49 and expression 7.53 (expression also varies the most). My strongest are subject 8.58 and focus 8.38.
- Critique text must name concrete, fixable things (light direction and ratio, background separation, crop, pose angles, hand placement, color grade), not generic praise.

4. POSTING WORKFLOW
- GET /picks?min_percentile=&grade=&not_posted=true, plus a posted_to table (instagram/modelmayhem/inpose/portfolio, date) and an endpoint to mark a photo as posted.
- Export: subject-aware 4:5 and 1:1 crops using the Apple Vision person/face rectangle (never cut off heads or hands), with a crop-offset override, an optional watermark, sRGB, and a Model Mayhem size preset. Create the destination folder only after the busy check passes.
- /results/{id} returns a short style_summary (lighting, mood, setup, wardrobe category only) for writing captions.

5. HOUSEKEEPING
- Settings: let me add /Volumes/ProfessionallyUnorganized to the allowed API paths, and default the allowlist to my photo volumes plus the workspace instead of my whole home folder.
- Add Swift unit tests for the scoring math and the API, and extend the Python tests. Update API.md and openapi.json. Split DashboardView.swift into smaller views.

DONE WHEN: tests pass; the app builds and runs; a 50-photo sample re-score shows the new distribution (target SD of at least 8, scores across at least 50 points of range, a real REJECT/MAYBE share). Then show me that histogram and a sample coaching report, and summarize the changed files. Don't re-score the whole library without asking me.
