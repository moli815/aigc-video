"use strict";
// Build-time packaging, not cross-function runtime imports or manually maintained copies.
const fs = require("fs");
const path = require("path");
const root = path.resolve(__dirname, "../cloudfunctions");
for (const name of ["bf-api", "bf-image", "bf-jobs"]) {
  const destination = path.join(root, name, "shared");
  fs.mkdirSync(destination, { recursive: true });
  for (const file of fs.readdirSync(path.join(root, "shared")).filter(x => x.endsWith(".js"))) {
    fs.copyFileSync(path.join(root, "shared", file), path.join(destination, file));
  }
}
