import os, sys
fixture, tool, args = sys.argv[1], sys.argv[2], " ".join(sys.argv[3:])
if os.path.exists(os.path.join(fixture, "hang")) and tool == "gh" and "/jobs" in args:
    import time
    time.sleep(5)
marker = os.path.join(fixture, "limited-once")
if tool == "gh" and "/actions/runs/30/jobs" in args and not os.path.exists(marker):
    open(marker, "w").close()
    sys.stderr.write("gh: API rate limit exceeded for user ID 1. (HTTP 403)\n")
    sys.exit(1)
sys.exit(100)
