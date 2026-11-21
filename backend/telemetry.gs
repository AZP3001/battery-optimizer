// Receives telemetry from the website and saves each upload as a JSON file in your Google Drive,
// in a folder named "Battery Optimizer telemetry". Setup: see backend/README.md.
const FOLDER = "Battery Optimizer telemetry";
const MAX_BYTES = 2 * 1024 * 1024;

function doPost(e) {
  const body = e && e.postData ? e.postData.contents : "";
  if (!body || body.length > MAX_BYTES) return reply("error: empty or too big");
  let data;
  try { data = JSON.parse(body); } catch (err) { return reply("error: not JSON"); }
  if (data.format !== 1 || !data.device) return reply("error: unknown format");
  const folders = DriveApp.getFoldersByName(FOLDER);
  const folder = folders.hasNext() ? folders.next() : DriveApp.createFolder(FOLDER);
  const model = String(data.device["ro.product.model"] || "unknown").replace(/[^\w.-]+/g, "_").slice(0, 40);
  folder.createFile(`${new Date().toISOString().replace(/[:.]/g, "-")}_${model}.json`, body, "application/json");
  return reply("ok");
}

function reply(text) { return ContentService.createTextOutput(text).setMimeType(ContentService.MimeType.TEXT); }
