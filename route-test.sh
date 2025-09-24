# Set once
BASE=http://localhost:8080

# Root
curl -fsSI "$BASE/" | sed -n '1,5p'
# Catalog
curl -fsSI "$BASE/catalog" | sed -n '1,5p'
# Product detail (use a known product id)
curl -fsSI "$BASE/catalog/d27cf49f-b689-4a75-a249-d373e0330bb5" | sed -n '1,5p'
# Cart
curl -fsSI "$BASE/cart" | sed -n '1,5p'
# Checkout
curl -fsSI "$BASE/checkout" | sed -n '1,5p'

BASE=http://localhost:8080
for p in / /catalog /catalog/d27cf49f-b689-4a75-a249-d373e0330bb5 /cart /checkout; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE$p")
  echo "$p -> $code"
done

BASE=http://localhost:8080
curl -fsS "$BASE/" | head -n 20
curl -fsS "$BASE/catalog" | head -n 20
curl -fsS "$BASE/catalog/d27cf49f-b689-4a75-a249-d373e0330bb5" | head -n 20
curl -fsS "$BASE/cart" | head -n 20
curl -fsS "$BASE/checkout" | head -n 20
