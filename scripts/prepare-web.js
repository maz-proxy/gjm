const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const webDir = path.join(root, "www");

fs.rmSync(webDir, { recursive: true, force: true });
fs.mkdirSync(webDir, { recursive: true });
fs.copyFileSync(path.join(root, "index.html"), path.join(webDir, "index.html"));
fs.copyFileSync(path.join(root, "favicon.ico"), path.join(webDir, "favicon.ico"));
fs.copyFileSync(path.join(root, "site.webmanifest"), path.join(webDir, "site.webmanifest"));
fs.cpSync(path.join(root, "assets"), path.join(webDir, "assets"), { recursive: true });
fs.copyFileSync(path.join(root, "assets", "favicon-32x32.png"), path.join(webDir, "favicon-32x32.png"));
fs.writeFileSync(path.join(webDir, ".nojekyll"), "");

const androidAppDir = path.join(root, "android", "app");
if (fs.existsSync(androidAppDir)) {
  const androidIconDir = path.join(androidAppDir, "src", "main", "res", "drawable-nodpi");
  fs.mkdirSync(androidIconDir, { recursive: true });
  fs.copyFileSync(
    path.join(root, "assets", "stock-opname-icon.png"),
    path.join(androidIconDir, "stock_opname_icon.png"),
  );
}
