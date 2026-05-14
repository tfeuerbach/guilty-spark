#!/bin/sh
# Replace Grafana's default branding with Guilty Spark at container start.
# Must run as root (user: "0:0" in docker-compose).

BRAND_DIR="/branding"
PUBLIC="/usr/share/grafana/public"

# Replace all favicon variants
find "$PUBLIC" -name "fav32*" -exec cp -f "$BRAND_DIR/favicon.png" {} \;
find "$PUBLIC" -name "apple-touch-icon*" -exec cp -f "$BRAND_DIR/apple-touch-icon.png" {} \;

# Replace all Grafana icon SVGs (sidebar + login page)
find "$PUBLIC" -name "grafana_icon*" -exec cp -f "$BRAND_DIR/logo.svg" {} \;
find "$PUBLIC" -name "grafana_typelogo*" -exec cp -f "$BRAND_DIR/login_logo.svg" {} \;

# Hardcode page title in the HTML template (replaces Go template variable)
sed -i 's/\[\[\.AppTitle\]\]/Guilty Spark/g' "$PUBLIC/views/index.html"

# Replace "Welcome to Grafana" in JS bundles
find "$PUBLIC/build" -name "*.js" -exec sed -i \
  's/Welcome to Grafana/Welcome to Guilty Spark/g' {} +

# Replace the AppTitle constant and any other title references in JS
find "$PUBLIC/build" -name "*.js" -exec sed -i \
  -e 's/this\.AppTitle="Grafana"/this.AppTitle="Guilty Spark"/g' \
  -e 's/title:"Grafana"/title:"Guilty Spark"/g' {} +

# Replace footer links: remove Support & Community, point Documentation to repo
find "$PUBLIC/build" -name "*.js" -exec sed -i \
  -e 's|"https://grafana.com/docs/grafana/latest/?utm_source=grafana_footer"|"https://github.com/tfeuerbach/guilty-spark"|g' \
  -e 's|{target:"_blank",id:"support",text:(0,c.t)("nav.help/support","Support"),icon:"question-circle",url:"https://grafana.com/products/enterprise/?utm_source=grafana_footer"},||g' \
  -e 's|{target:"_blank",id:"community",text:(0,c.t)("nav.help/community","Community"),icon:"comments-alt",url:"https://community.grafana.com/?utm_source=grafana_footer"}||g' \
  {} +

# Replace version string and changelog URL
find "$PUBLIC/build" -name "*.js" -exec sed -i \
  -e 's|text:m.versionString|text:"Guilty Spark v1.0.0"|g' \
  -e 's|subTitle:a.\$.buildInfo.versionString|subTitle:"v1.0.0"|g' \
  -e 's|https://github.com/grafana/grafana/blob/main/CHANGELOG.md|https://github.com/tfeuerbach/guilty-spark|g' \
  -e 's|n.OpenSource="Open Source"|n.OpenSource=""|g' \
  {} +

# Start Grafana
exec /run.sh
