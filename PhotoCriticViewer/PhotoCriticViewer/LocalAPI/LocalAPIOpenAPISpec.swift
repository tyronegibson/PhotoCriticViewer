import Foundation

/// Static OpenAPI 3.0 document for GET /openapi.json. Kept as a literal string (not built
/// from the route table) since it's a one-time documentation deliverable, not something that
/// needs to stay byte-for-byte derived from the Swift routing code -- see API.md for the
/// human-readable version with curl examples.
enum LocalAPIOpenAPISpec {
    static let json = """
    {
      "openapi": "3.0.3",
      "info": {
        "title": "PhotoCriticViewer Local Control API",
        "version": "2.0.0",
        "description": "Control API for driving PhotoCriticViewer. Binds to 127.0.0.1, plus this Mac's Tailscale address only when Settings' Remote Access is on. Every endpoint except GET /health requires Authorization: Bearer <token> (see ~/.photocritic/api_token)."
      },
      "servers": [{ "url": "http://127.0.0.1:8765" }],
      "components": {
        "securitySchemes": {
          "bearerAuth": { "type": "http", "scheme": "bearer" }
        },
        "schemas": {
          "Error": {
            "type": "object",
            "properties": {
              "error": {
                "type": "object",
                "properties": {
                  "code": { "type": "string" },
                  "message": { "type": "string" }
                }
              }
            }
          },
          "ReviewedPhoto": {
            "type": "object",
            "properties": {
              "id": { "type": "integer" },
              "shoot_id": { "type": "integer" },
              "path": { "type": "string" },
              "filename": { "type": "string" },
              "shoot": { "type": "string" },
              "score": { "type": "number", "description": "Raw weighted-category score, 0-100 (photocritic.scoring)" },
              "calibrated_score": { "type": "number", "nullable": true, "description": "Percentile-within-library, 0-100 -- spreads out by construction even if raw scores cluster" },
              "percentile_shoot": { "type": "number", "nullable": true },
              "percentile_library": { "type": "number", "nullable": true },
              "scores": { "type": "object", "description": "Per-category 0-10 scores" },
              "classification": { "type": "string", "nullable": true },
              "recommendation": { "type": "string", "nullable": true },
              "critique": { "type": "string", "nullable": true },
              "tags": { "type": "array", "items": { "type": "string" } },
              "reviewed_at": { "type": "string", "nullable": true }
            }
          }
        }
      },
      "security": [{ "bearerAuth": [] }],
      "paths": {
        "/health": {
          "get": {
            "summary": "Liveness check. No auth required.",
            "security": [],
            "responses": { "200": { "description": "OK" } }
          }
        },
        "/open": {
          "post": {
            "summary": "Ensure a folder is organized into shoot(s) and return its photos. Runs organize.py synchronously and waits for it to finish.",
            "requestBody": {
              "required": true,
              "content": { "application/json": { "schema": { "type": "object", "properties": { "path": { "type": "string" } }, "required": ["path"] } } }
            },
            "responses": {
              "200": { "description": "{ shoot_ids: [...], photos: [{id, path, filename, shoot_id}] }" },
              "400": { "description": "Bad request", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Error" } } } },
              "409": { "description": "Another ingest/evaluate job is already running" }
            }
          }
        },
        "/critique": {
          "post": {
            "summary": "Run the real AI evaluation pipeline (evaluate.py) on the given file ids (evaluates ONLY those files, not their whole shoot) or the shoot at the given path (evaluates the whole shoot). Always accepted and queued -- never 409; jobs run one at a time, in arrival order, persisted in SQLite so they survive an app relaunch (a job still in-flight at relaunch is marked failed, not resumed). Poll GET /jobs/{id}.",
            "requestBody": {
              "required": true,
              "content": { "application/json": { "schema": { "type": "object", "properties": { "ids": { "type": "array", "items": { "type": "integer" } }, "path": { "type": "string" } } } } }
            },
            "responses": {
              "202": { "description": "{ job_id: \\"...\\" }" },
              "404": { "description": "Shoot not found (path case) -- call /open first" }
            }
          }
        },
        "/": {
          "get": { "summary": "Mobile web UI (static page; no auth -- it calls the endpoints below with the bearer token).", "security": [],
                   "responses": { "200": { "description": "text/html" } } }
        },
        "/remote/config": {
          "get": { "summary": "What a remote client needs: app_version, remote_exports_dir, export_presets, preview_sizes.",
                   "responses": { "200": { "description": "JSON object" } } }
        },
        "/shoots": {
          "get": { "summary": "All shoots, newest first, with keep/maybe/reject counts.",
                   "responses": { "200": { "description": "[{ id, name, parent, folder_path, total_files, evaluated, keep, maybe, reject }]" } } }
        },
        "/shoots/{id}/photos": {
          "get": {
            "summary": "A shoot's photos for a grid.",
            "parameters": [
              { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } },
              { "name": "sort", "in": "query", "schema": { "type": "string", "enum": ["score", "filename"] } },
              { "name": "recommendation", "in": "query", "schema": { "type": "string", "enum": ["KEEP", "MAYBE", "REJECT"] } }
            ],
            "responses": { "200": { "description": "[{ id, filename, has_preview, score?, classification?, recommendation?, group_id?, group_rank?, group_role?, look?, person? }]" } }
          }
        },
        "/previews/{id}": {
          "get": {
            "summary": "Preview JPEG for a file (never the RAW). ?w= snaps up to 256/512/1024/2048 and is cached.",
            "parameters": [
              { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } },
              { "name": "w", "in": "query", "schema": { "type": "integer" } }
            ],
            "responses": { "200": { "description": "image/jpeg" }, "404": { "description": "No preview for this file" } }
          }
        },
        "/jobs": {
          "get": {
            "summary": "Recent /critique jobs, newest first.",
            "parameters": [{ "name": "limit", "in": "query", "schema": { "type": "integer", "maximum": 200 } }],
            "responses": { "200": { "description": "[{ id, status, params, created_at, stage?, current?, total?, error?, result? }]" } }
          }
        },
        "/downloads": {
          "get": {
            "summary": "Download one exported image. Only files under <workspace>/exports with an image extension.",
            "parameters": [{ "name": "path", "in": "query", "required": true, "schema": { "type": "string" } }],
            "responses": { "200": { "description": "The file, as an attachment" }, "403": { "description": "Outside exports/ or not an image" } }
          }
        },
        "/jobs/{id}": {
          "get": {
            "summary": "Status/progress/result of a /critique job.",
            "parameters": [{ "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }],
            "responses": {
              "200": { "description": "{ id, status: queued|running|done|failed, stage?, current?, total?, result?, error? }" },
              "404": { "description": "Unknown job id (also returned for a job pruned after 24h)" }
            }
          }
        },
        "/results": {
          "get": {
            "summary": "List evaluated photos across all shoots.",
            "parameters": [
              { "name": "min_score", "in": "query", "schema": { "type": "number" } },
              { "name": "sort", "in": "query", "schema": { "type": "string", "enum": ["score_desc", "score_asc", "filename"] } },
              { "name": "limit", "in": "query", "schema": { "type": "integer", "maximum": 2000 } }
            ],
            "responses": {
              "200": { "description": "Array of ReviewedPhoto", "content": { "application/json": { "schema": { "type": "array", "items": { "$ref": "#/components/schemas/ReviewedPhoto" } } } } }
            }
          }
        },
        "/results/{id}": {
          "get": {
            "summary": "Full detail for one photo, including per-category reasons and a style_summary for captions.",
            "parameters": [{ "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } }],
            "responses": {
              "200": { "description": "Full evaluation (scores, category_reasons, critique, strengths/weaknesses, style_summary), technical, metadata, group, and posted_to detail" },
              "404": { "description": "No file with that id" }
            }
          }
        },
        "/report": {
          "get": {
            "summary": "Coaching report: strongest/weakest categories, trends by month and by shoot, recurring critique themes, 10 best/10 weakest frames, and 3-5 concrete things to practice.",
            "parameters": [
              { "name": "shoot", "in": "query", "schema": { "type": "integer" }, "description": "Scope to one shoot_id" },
              { "name": "since", "in": "query", "schema": { "type": "string" }, "description": "ISO date/datetime -- only evaluations at or after this" }
            ],
            "responses": {
              "200": { "description": "{ photo_count, strongest_categories, weakest_categories, trend_by_month, trend_by_shoot, recurring_issues, best_photos, weakest_photos, things_to_practice }" }
            }
          }
        },
        "/picks": {
          "get": {
            "summary": "Posting-workflow picks: evaluated photos filtered by minimum calibrated percentile and/or exact grade, optionally excluding anything already posted to any platform.",
            "parameters": [
              { "name": "min_percentile", "in": "query", "schema": { "type": "number" } },
              { "name": "grade", "in": "query", "schema": { "type": "string" } },
              { "name": "not_posted", "in": "query", "schema": { "type": "string", "enum": ["true"] } },
              { "name": "limit", "in": "query", "schema": { "type": "integer", "maximum": 2000 } }
            ],
            "responses": {
              "200": { "description": "Array of ReviewedPhoto", "content": { "application/json": { "schema": { "type": "array", "items": { "$ref": "#/components/schemas/ReviewedPhoto" } } } } }
            }
          }
        },
        "/posted": {
          "post": {
            "summary": "Mark a photo as posted to a platform (instagram, modelmayhem, inpose, portfolio, or any name you like).",
            "requestBody": {
              "required": true,
              "content": { "application/json": { "schema": { "type": "object", "properties": { "id": { "type": "integer" }, "platform": { "type": "string" } }, "required": ["id", "platform"] } } }
            },
            "responses": {
              "200": { "description": "{ id, platform, posted: true }" },
              "400": { "description": "Bad request" },
              "409": { "description": "Another curation/export job is already running" }
            }
          }
        },
        "/export": {
          "post": {
            "summary": "Export photos as subject-aware-cropped JPEGs (decoded fresh from the RAW at full resolution; crop uses Apple Vision face/person detection so a head or hand is never cut off, unless crop_offset overrides it). EXIF is copied from the original; GPS is stripped. sRGB color space is applied explicitly. Runs synchronously.",
            "requestBody": {
              "required": true,
              "content": {
                "application/json": {
                  "schema": {
                    "type": "object",
                    "properties": {
                      "ids": { "type": "array", "items": { "type": "integer" } },
                      "dest": { "type": "string" },
                      "preset": { "type": "string", "enum": ["instagram_4x5", "instagram_square", "instagram_story", "modelmayhem", "original"], "default": "original" },
                      "long_edge": { "type": "integer" },
                      "quality": { "type": "integer", "minimum": 1, "maximum": 100 },
                      "crop_offset": { "type": "object", "properties": { "x": { "type": "number" }, "y": { "type": "number" } }, "description": "Normalized 0-1 center point override; skips Vision detection" },
                      "watermark": { "type": "string", "description": "Optional text drawn bottom-right, semi-transparent" }
                    },
                    "required": ["ids", "dest"]
                  }
                }
              }
            },
            "responses": {
              "200": { "description": "{ results: [{file_id, path} | {file_id, error}], exported, failed }" },
              "400": { "description": "Bad request" },
              "409": { "description": "Another curation/export job is already running" }
            }
          }
        },
        "/openapi.json": {
          "get": { "summary": "This document.", "responses": { "200": { "description": "OK" } } }
        }
      }
    }
    """
}
