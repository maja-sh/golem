# Real Test: Bookmark Manager REST API

**Difficulty:** Hard
**Expected steps:** 20-40
**Tools exercised:** shell, write_file, edit_file, read_file, glob, grep, sub_agent
**Validates:** Full planning, sub-agents, complex multi-file project

## Goal

Build a REST API with Flask for a bookmark manager. Requirements:
- CRUD endpoints for bookmarks (title, url, description, tags)
- SQLite storage with proper schema
- Tag filtering: GET /bookmarks?tag=python
- Search: GET /bookmarks?q=search+term
- Input validation and error handling
- Unit tests with pytest (test all endpoints)
- A Makefile with targets: install, test, run
- Put everything in /home/agent/bookmark-api/
