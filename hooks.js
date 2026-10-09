// Adds or removes Claude Pet's hooks in Claude Code's settings.json, leaving
// every other setting (and its order) as it was. Used by install.sh:
//   osascript -l JavaScript hooks.js <settings.json> <ClaudePet binary> add|remove
ObjC.import("Foundation");

// Each event the pet reacts to. Notification is limited to the prompts that
// wait on you; PermissionRequest catches the same thing without its delay.
const EVENTS = {
  SessionStart: null,
  UserPromptSubmit: null,
  PreToolUse: null,
  PostToolUse: null,
  PostToolUseFailure: null,
  PermissionRequest: null,
  Notification: "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
  Stop: null,
  StopFailure: null,
  SessionEnd: null,
};

function run([path, binary, mode]) {
  const exists = $.NSFileManager.defaultManager.fileExistsAtPath(path);
  const text = exists
    ? $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js
    : "{}";
  let settings;
  try {
    settings = JSON.parse(text.trim() || "{}");
  } catch (e) {
    throw new Error(`${path} isn't valid JSON, so it was left alone: ${e.message}`);
  }

  // Drop any of our earlier entries first, so running this twice is harmless.
  const ours = (group) => (group.hooks || []).some((h) => String(h.command || "").endsWith("/ClaudePet"));
  const hooks = settings.hooks || {};
  for (const event of Object.keys(hooks)) {
    hooks[event] = hooks[event].filter((group) => !ours(group));
    if (hooks[event].length === 0) delete hooks[event];
  }

  if (mode === "add") {
    // Exec form (no shell) and in the background, so Claude never waits on the pet.
    const handler = { type: "command", command: binary, args: ["--hook"], async: true };
    for (const [event, matcher] of Object.entries(EVENTS)) {
      (hooks[event] = hooks[event] || []).push(matcher ? { matcher, hooks: [handler] } : { hooks: [handler] });
    }
  }

  if (Object.keys(hooks).length) settings.hooks = hooks;
  else delete settings.hooks;

  $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
    $(path).stringByDeletingLastPathComponent, true, $(), null);
  $(JSON.stringify(settings, null, 2) + "\n")
    .writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  return mode === "add" ? `Claude Pet hooks added to ${path}` : `Claude Pet hooks removed from ${path}`;
}
