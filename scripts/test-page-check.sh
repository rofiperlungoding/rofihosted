#!/data/data/com.termux/files/usr/bin/sh
set -e
if [ -f ~/.hp-server.env ]; then set -a; . ~/.hp-server.env; set +a; fi
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" -o /dev/null https://app.rofihosted.space/login/submit
echo "--- /projects page structure check ---"
PAGE=$(curl -s -b "$CJ" https://app.rofihosted.space/projects)
echo "has topbar: $(echo "$PAGE" | grep -c 'class="topbar"')"
echo "has page-title: $(echo "$PAGE" | grep -c 'page-title')"
echo "has sidebar: $(echo "$PAGE" | grep -c 'class="sidebar"')"
echo "has nav-spacer: $(echo "$PAGE" | grep -c 'nav-spacer')"
echo "has Account section: $(echo "$PAGE" | grep -c 'Account')"
echo "has theme-toggle: $(echo "$PAGE" | grep -c 'theme-toggle')"
echo "has ws-badge: $(echo "$PAGE" | grep -c 'ws-badge')"
echo "has projects-grid or empty-state: $(echo "$PAGE" | grep -c 'projects-grid\|empty-state')"
echo "has New project btn: $(echo "$PAGE" | grep -c 'new-project-btn')"
echo "title: $(echo "$PAGE" | grep -oE '<title>[^<]+' | head -1)"
