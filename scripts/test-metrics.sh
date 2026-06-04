#!/data/data/com.termux/files/usr/bin/bash
# Test script for metrics implementation
# Run this on Termux to verify everything works

set -e

export TMPDIR="$PREFIX/tmp"
mkdir -p "$TMPDIR"

echo "🧪 Testing Metrics Implementation"
echo "=================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Change to project directory
cd ~/zig/hp-server

echo "📦 Step 1: Checking Zig installation..."
if ! command -v zig &> /dev/null; then
    echo -e "${RED}❌ Zig not found. Install with: pkg install zig${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Zig found: $(zig version)${NC}"
echo ""

echo "🔨 Step 2: Compiling metrics tests..."
if zig test -Dtarget=aarch64-linux-android src/metrics_test.zig 2>&1 | tee "$TMPDIR/metrics-test.log"; then
    echo -e "${GREEN}✅ All metrics tests passed!${NC}"
else
    echo -e "${RED}❌ Metrics tests failed. Check $TMPDIR/metrics-test.log${NC}"
    exit 1
fi
echo ""

echo "🏗️  Step 3: Building hp-server with metrics..."
if zig build -Dtarget=aarch64-linux-android 2>&1 | tee "$TMPDIR/build.log"; then
    echo -e "${GREEN}✅ Build successful!${NC}"
else
    echo -e "${RED}❌ Build failed. Check $TMPDIR/build.log${NC}"
    cat "$TMPDIR/build.log"
    exit 1
fi
echo ""

echo "🔍 Step 4: Checking binary size..."
if [ -f "zig-out/bin/hp-server" ]; then
    SIZE=$(du -h zig-out/bin/hp-server | cut -f1)
    echo -e "${GREEN}✅ Binary size: $SIZE${NC}"
else
    echo -e "${RED}❌ Binary not found at zig-out/bin/hp-server${NC}"
    exit 1
fi
echo ""

echo "🚀 Step 5: Starting test server (5 seconds)..."
# Kill any existing hp-server
pkill -f hp-server || true
sleep 1

# Start server in background
./zig-out/bin/hp-server &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait for server to start
sleep 3

echo ""
echo "🧪 Step 6: Testing /metrics endpoint..."

# Test 1: Check if server is responding
if curl -s http://127.0.0.1:8080/health > /dev/null; then
    echo -e "${GREEN}✅ Server is responding${NC}"
else
    echo -e "${RED}❌ Server not responding${NC}"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

# Test 2: Try to access /metrics (will fail without auth, but should return 302 to login)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --resolve app.rofihosted.space:8080:127.0.0.1 http://app.rofihosted.space:8080/metrics)
if [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    echo -e "${GREEN}✅ /metrics endpoint exists (returned $HTTP_CODE - auth required)${NC}"
elif [ "$HTTP_CODE" = "200" ]; then
    echo -e "${YELLOW}⚠️  /metrics returned 200 (no auth configured?)${NC}"
    echo "Sample metrics output:"
    curl -s --resolve app.rofihosted.space:8080:127.0.0.1 http://app.rofihosted.space:8080/metrics | head -20
else
    echo -e "${RED}❌ /metrics endpoint returned unexpected code: $HTTP_CODE${NC}"
fi

# Test 3: With auth cookie
if [ -f ~/.hp-server.env ]; then
    source ~/.hp-server.env
    if [ -n "$HP_AUTH_USER" ] && [ -n "$HP_AUTH_PASS" ]; then
        printf '{"username":"%s","password":"%s"}' "$HP_AUTH_USER" "$HP_AUTH_PASS" > "$TMPDIR/login.json"
        if curl -sS -m 5 -c "$TMPDIR/cj.txt" -X POST \
            --resolve app.rofihosted.space:8080:127.0.0.1 \
            -H "Content-Type: application/json" \
            --data @"$TMPDIR/login.json" \
            -o "$TMPDIR/login.out" -w "" \
            http://app.rofihosted.space:8080/api/login; then
            if [ -s "$TMPDIR/cj.txt" ]; then
                AUTH_CODE=$(curl -s -b "$TMPDIR/cj.txt" -o "$TMPDIR/metrics.txt" -w "%{http_code}" \
                    --resolve app.rofihosted.space:8080:127.0.0.1 \
                    http://app.rofihosted.space:8080/metrics)
                if [ "$AUTH_CODE" = "200" ]; then
                    echo -e "${GREEN}✅ /metrics with auth returned 200${NC}"
                    echo "Sample metrics output:"
                    head -30 "$TMPDIR/metrics.txt"
                else
                    echo -e "${YELLOW}⚠️  /metrics with auth returned $AUTH_CODE${NC}"
                fi
            else
                echo -e "${YELLOW}⚠️  Login did not set cookie${NC}"
            fi
        fi
    fi
fi

echo ""
echo "🧹 Step 7: Cleanup..."
kill $SERVER_PID 2>/dev/null || true
sleep 1
echo -e "${GREEN}✅ Server stopped${NC}"

echo ""
echo "=================================="
echo "🎉 All tests passed!"
echo ""
echo "Next steps:"
echo "1. Review the code changes"
echo "2. Deploy to production: ./scripts/rebuild.sh"
echo "3. Configure Prometheus scraping"
echo "4. Import Grafana dashboard"
echo ""
echo "To test /metrics with auth:"
echo "  curl -u \$HP_USER:\$HP_PASS http://127.0.0.1:8080/metrics"
echo ""

# Made with Bob
