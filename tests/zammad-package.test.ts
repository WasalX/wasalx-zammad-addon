// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";

type PackageFile = { location: string; permission: string; content: string };
type ZammadPackage = { name: string; version: string; license: string; files: PackageFile[] };

const workspace = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const metadata = JSON.parse(
  await readFile(path.join(workspace, "zammad-package/package-source.json"), "utf8"),
) as { name: string; version: string };
const compatibility = JSON.parse(
  await readFile(path.join(workspace, "zammad-package/compatibility-artifacts.json"), "utf8"),
) as { schemaVersion: number; artifacts: Record<string, Record<string, string>> };
const packageFile = path.join(workspace, "build/zammad", `${metadata.name}-${metadata.version}.zpm`);
const packageManifestFile = path.join(workspace, "build/zammad", `${metadata.name}-${metadata.version}.manifest.json`);
const unpacker = path.join(workspace, "infra/docker/full/zammad/unpack-zpm.mjs");

async function builtPackage(): Promise<ZammadPackage> {
  return JSON.parse(await readFile(packageFile, "utf8")) as ZammadPackage;
}

function content(value: ZammadPackage, location: string): string {
  return Buffer.from(value.files.find((file) => file.location === location)?.content ?? "", "base64").toString("utf8");
}

test("the package build records exact source, packaged, and archive bytes", async () => {
  const archive = await readFile(packageFile);
  const packageValue = JSON.parse(new TextDecoder().decode(archive)) as ZammadPackage;
  const manifest = JSON.parse(await readFile(packageManifestFile, "utf8")) as {
    package: { path: string; permission: string; bytes: number; sha256: string };
    files: Array<{
      location: string;
      permission: string;
      source: { path: string; permission: string; bytes: number; sha256: string };
      packaged: { path: string; permission: string; bytes: number; sha256: string };
    }>;
  };
  assert.equal(manifest.package.path, `build/zammad/${metadata.name}-${metadata.version}.zpm`);
  assert.equal(manifest.package.permission, "644");
  assert.equal(manifest.package.bytes, archive.byteLength);
  assert.equal(manifest.package.sha256, createHash("sha256").update(archive).digest("hex"));
  assert.ok(manifest.files.length > 0);
  assert.deepEqual(
    manifest.files.map(({ location }) => location).sort(),
    packageValue.files.map(({ location }) => location).sort(),
  );
  const packagedByLocation = new Map(packageValue.files.map((file) => [file.location, file]));
  for (const file of manifest.files) {
    assert.equal(file.permission, "644");
    assert.equal(file.source.path, `zammad-package/${file.location}`);
    assert.equal(file.source.permission, "644");
    assert.equal(file.packaged.path, file.location);
    assert.equal(file.packaged.permission, "644");
    const source = await readFile(path.join(workspace, file.source.path));
    const packaged = Buffer.from(packagedByLocation.get(file.location)?.content ?? "", "base64");
    assert.equal(file.source.bytes, source.byteLength);
    assert.equal(file.source.sha256, createHash("sha256").update(source).digest("hex"));
    assert.equal(file.packaged.bytes, packaged.byteLength);
    assert.equal(file.packaged.sha256, createHash("sha256").update(packaged).digest("hex"));
  }
});

function singleLinePoEntries(source: string): Map<string, string> {
  return new Map(
    [...source.matchAll(/^msgid (".*")\nmsgstr (".*")$/gmu)]
      .map((match): [string, string] => [JSON.parse(match[1]) as string, JSON.parse(match[2]) as string])
      .filter(([message]) => message.length > 0),
  );
}

async function rubyFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await rubyFiles(absolute));
    else if (entry.name.endsWith(".rb")) files.push(absolute);
  }
  return files;
}

function packageArtifact(version: string, files: Array<{ location: string; body: string }>) {
  return `${JSON.stringify({
    name: "wasalx",
    version,
    files: files.map(({ location, body }) => ({
      location,
      permission: "644",
      content: Buffer.from(body).toString("base64"),
    })),
  })}\n`;
}

test("the package unpacker rejects upstream collisions before writes and permits prior package-owned files", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "wasalx-zammad-unpack-"));
  try {
    const collisionDestination = path.join(directory, "collision");
    const collisionArtifact = path.join(directory, "collision.zpm");
    const upstreamFile = path.join(collisionDestination, "app/core.ts");
    const unwrittenFile = path.join(collisionDestination, "app/new.ts");
    await mkdir(path.dirname(upstreamFile), { recursive: true });
    await writeFile(upstreamFile, "same bytes\n");
    await writeFile(collisionArtifact, packageArtifact("0.5.27", [
      { location: "app/new.ts", body: "must not be written\n" },
      { location: "app/core.ts", body: "same bytes\n" },
    ]));

    const collision = spawnSync(process.execPath, [
      unpacker, collisionArtifact, collisionDestination, "wasalx", "0.5.27",
    ], { encoding: "utf8" });
    assert.notEqual(collision.status, 0);
    assert.match(collision.stderr, /app\/core\.ts collides with an existing non-package file/u);
    assert.equal(await readFile(upstreamFile, "utf8"), "same bytes\n");
    await assert.rejects(readFile(unwrittenFile), (error: NodeJS.ErrnoException) => error.code === "ENOENT");

    const upgradeDestination = path.join(directory, "upgrade");
    const priorArtifact = path.join(upgradeDestination, "contrib/wasalx.zpm");
    const ownedFile = path.join(upgradeDestination, "app/owned.ts");
    const upgradeArtifact = path.join(directory, "upgrade.zpm");
    await mkdir(path.dirname(priorArtifact), { recursive: true });
    await mkdir(path.dirname(ownedFile), { recursive: true });
    await writeFile(priorArtifact, packageArtifact("0.5.26", [
      { location: "app/owned.ts", body: "prior package\n" },
    ]));
    await writeFile(ownedFile, "prior package\n");
    await writeFile(upgradeArtifact, packageArtifact("0.5.27", [
      { location: "app/owned.ts", body: "current package\n" },
      { location: "app/new.ts", body: "new package file\n" },
    ]));

    const upgrade = spawnSync(process.execPath, [
      unpacker, upgradeArtifact, upgradeDestination, "wasalx", "0.5.27",
    ], { encoding: "utf8" });
    assert.equal(upgrade.status, 0, upgrade.stderr || upgrade.stdout);
    assert.equal(await readFile(ownedFile, "utf8"), "current package\n");
    assert.equal(await readFile(path.join(upgradeDestination, "app/new.ts"), "utf8"), "new package file\n");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Zammad package is installable and contains the thin runtime hook", async () => {
  const value = await builtPackage();
  assert.equal(value.name, "wasalx");
  assert.equal(value.version, metadata.version);
  assert.equal(value.license, "AGPL-3.0-only");
  for (const file of value.files) assert.doesNotMatch(content(value, file.location), /\r\n/u, file.location);
  for (const required of [
    "app/jobs/communicate_wasalx_job.rb",
    "app/jobs/wasalx_ticket_state_job.rb",
    "app/jobs/wasalx_ticket_routing_job.rb",
    "app/jobs/wasalx_group_workspace_upload_cleanup_job.rb",
    "app/models/ticket/article/enqueue_communicate_wasalx_job.rb",
    "app/models/ticket/enqueue_wasalx_ticket_state_job.rb",
    "app/services/service/ticket/article/type/wasalx_group_message/deliver.rb",
    "app/services/service/ticket/wasalx_panel.rb",
    "app/controllers/api/v1/wasalx_controller.rb",
    "app/frontend/apps/desktop/pages/wasalx-groups/routes.ts",
    "app/frontend/apps/desktop/pages/wasalx-groups/composerRecovery.ts",
    "app/frontend/apps/desktop/pages/wasalx-groups/views/WasalxGroups.vue",
    "app/frontend/apps/desktop/pages/ticket/components/TicketSidebar/plugins/wasalx.ts",
    "app/frontend/apps/desktop/pages/ticket/components/TicketSidebar/TicketSidebarWasalx/TicketSidebarWasalx.vue",
    "app/frontend/shared/entities/ticket-article/action/plugins/wasalx.ts",
    "config/initializers/wasalx.rb",
    "config/routes/wasalx.rb",
    "db/addon/wasalx/202608090001_create_wasalx_channel.rb",
    "db/addon/wasalx/202608090002_add_wasalx_routing_attributes.rb",
    "db/addon/wasalx/202608150004_add_client_routing_attributes.rb",
    "db/addon/wasalx/202608200005_add_group_workspace_operation_key.rb",
    "db/addon/wasalx/202610180002_extend_wasalx_ticket_operation_cancellation.rb",
    "db/addon/wasalx/202608230006_schedule_group_workspace_upload_cleanup.rb",
    "db/addon/wasalx/202608240007_sync_wasalx_arabic_translations.rb",
    "db/addon/wasalx/202608240008_enable_wasalx_modern_desktop_ui.rb",
    "db/addon/wasalx/202608240009_sync_wasalx_agent_ui_translations.rb",
    "db/addon/wasalx/202609010012_materialize_wasalx_client_routing_attributes.rb",
    "db/addon/wasalx/202609020013_sync_wasalx_delivery_failure_translations.rb",
    "db/addon/wasalx/202609020014_hide_wasalx_client_routing_attributes.rb",
    "db/addon/wasalx/202609020015_add_wasalx_assignment_revision.rb",
    "i18n/wasalx.ar.po",
    "lib/wasalx/client.rb",
    "lib/wasalx/group_workspace.rb",
    "lib/wasalx/native_identifiers.rb",
  ]) assert.ok(value.files.some((file) => file.location === required), `missing ${required}`);
  assert.ok(value.files.every((file) => file.permission === "644" && Buffer.from(file.content, "base64").length > 0));
  assert.ok(!value.files.some((file) => file.location === "app/models/channel/driver/wasalx.rb"));
});

test("package-owned Arabic catalog covers every WasalX frontend label missing from Zammad 7.1.3", async () => {
  const value = await builtPackage();
  const translations = singleLinePoEntries(content(value, "i18n/wasalx.ar.po"));
  const zammad713ArabicSources = new Set([
    "Attach files", "Attachment", "Attachments", "Audio file", "Cancel", "Closed", "Connecting",
    "Create ticket", "Document file", "Image", "Image file", "Loading…", "Message", "Open", "Read",
    "Related tickets", "Remove", "Send", "Sending…", "Ticket", "Ticket title", "Try again", "Unknown",
    "Uploading…", "Video", "Video file", "WhatsApp", "WhatsApp message", "message",
  ]);
  const frontendSources = value.files.filter((file) => file.location.startsWith("app/frontend/") && /\.(?:ts|vue)$/u.test(file.location));
  const usedLabels = new Set<string>();
  for (const file of frontendSources) {
    for (const match of content(value, file.location).matchAll(/(?:\$t|__)\('([^']+)'\)/gu)) usedLabels.add(match[1]);
  }
  const missing = [...usedLabels].filter((label) => !zammad713ArabicSources.has(label) && !translations.has(label));
  assert.deepEqual(missing, []);
  for (const [source, target] of translations) {
    assert.match(target, /[\u0600-\u06ff]/u, `${source} must have an Arabic translation`);
    assert.notEqual(target, source);
  }

  const migration = content(value, "db/addon/wasalx/202608240007_sync_wasalx_arabic_translations.rb");
  const agentUiMigration = content(value, "db/addon/wasalx/202608240009_sync_wasalx_agent_ui_translations.rb");
  const deliveryFailureMigration = content(value, "db/addon/wasalx/202609020013_sync_wasalx_delivery_failure_translations.rb");
  assert.match(migration, /Translation\.sync_locale_from_po\('ar'\)/u);
  assert.match(migration, /synchronized_from_translation_file: TRANSLATION_FILE/u);
  assert.match(migration, /translation\.target == translation\.target_initial/u);
  assert.match(migration, /is_synchronized_from_codebase: false/u);
  assert.match(agentUiMigration, /Translation\.sync_locale_from_po\('ar'\)/u);
  assert.match(agentUiMigration, /def self\.down; end/u);
  assert.match(deliveryFailureMigration, /Translation\.sync_locale_from_po\('ar'\)/u);
  assert.match(deliveryFailureMigration, /def self\.down; end/u);
});

test("runtime hook mirrors Zammad after-commit/job/service conventions without patching native WhatsApp", async () => {
  const value = await builtPackage();
  const concern = content(value, "app/models/ticket/article/enqueue_communicate_wasalx_job.rb");
  const job = content(value, "app/jobs/communicate_wasalx_job.rb");
  const ticketConcern = content(value, "app/models/ticket/enqueue_wasalx_ticket_state_job.rb");
  const ticketJob = content(value, "app/jobs/wasalx_ticket_state_job.rb");
  const routingJob = content(value, "app/jobs/wasalx_ticket_routing_job.rb");
  const initializer = content(value, "config/initializers/wasalx.rb");
  const deliver = content(value, "app/services/service/ticket/article/type/wasalx_group_message/deliver.rb");
  assert.match(concern, /after_create_commit/);
  assert.match(concern, /def wasalx_agent_outbound\?/);
  assert.match(concern, /sender&\.name == 'Agent'/);
  assert.match(concern, /type&\.name == 'wasalx group message'/);
  assert.match(concern, /return true if Setting\.get\('import_mode'\) \|\| !wasalx_agent_outbound\?/);
  assert.match(concern, /internal != false/);
  assert.match(concern, /wasalx_provider_origin\?/);
  assert.match(concern, /Sent from WhatsApp device/);
  assert.match(job, /retry_on Wasalx::Client::TemporaryRequestFailed, attempts: 4/);
  assert.match(initializer, /Rails\.application\.config\.to_prepare/);
  assert.match(initializer, /Ticket::Article\.include\(article_concern\)/);
  assert.match(initializer, /Ticket\.include\(ticket_concern\)/);
  assert.match(ticketConcern, /after_update :ticket_enqueue_wasalx_ticket_state_job/);
  assert.match(ticketConcern, /saved_change_to_state_id\?/);
  assert.match(ticketConcern, /self\.class\.current_transaction/);
  assert.match(ticketConcern, /unless transaction\.open\?/);
  assert.match(ticketConcern, /transaction\.after_commit/);
  assert.match(ticketConcern, /Ticket::StateType\.lookup/);
  assert.match(ticketConcern, /transition_time = updated_at\.utc\.iso8601\(6\)/);
  assert.match(ticketJob, /scope: 'zammad:ticket-state'/);
  assert.match(ticketJob, /retry_on Wasalx::Client::TemporaryRequestFailed, attempts: 8/);
  assert.match(concern, /sender\.name != 'Customer'/);
  assert.match(concern, /type\.name != 'email'/);
  assert.match(concern, /application_handle_info_postmaster == true/);
  assert.match(concern, /after_create :ticket_article_enqueue_wasalx_routing_job/u);
  assert.doesNotMatch(concern, /after_create_commit :ticket_article_enqueue_wasalx_routing_job/u);
  assert.match(concern, /'is-auto-response'/);
  assert.match(concern, /sender_email/);
  assert.match(concern, /ticket\.with_lock/u);
  assert.match(concern, /wasalx_client_route_status: 'PENDING'/u);
  assert.match(concern, /expected_assignment_revision/u);
  assert.match(routingJob, /self\.enqueue_after_transaction_commit = false/u);
  assert.match(routingJob, /attempts: :unlimited/u);
  assert.match(routingJob, /scope: 'zammad:routing'/);
  assert.match(routingJob, /article_id: input\.fetch\(:article_id\)/);
  assert.match(routingJob, /routing\/acknowledgement/);
  assert.match(routingJob, /phase == 'ACKNOWLEDGEMENT'/u);
  assert.match(routingJob, /wasalx_email_routing_ack_failure_noted/u);
  assert.match(routingJob, /return perform_acknowledgement\(input\)/u);
  assert.match(routingJob, /acknowledgement_payload = \{[\s\S]*'phase' => 'ACKNOWLEDGEMENT'/u);
  assert.match(routingJob, /self\.class\.perform_later\(acknowledgement_payload\)/u);
  for (const field of ["route_id", "ticket_id", "article_id", "application_status", "observed_group_id", "observed_owner_id"])
    assert.match(routingJob, new RegExp(`'${field}' =>`, "u"));
  assert.match(routingJob, /return if %w\[APPLIED FAILED_TERMINAL\]\.include\?\(source_state\)/u);
  assert.match(routingJob, /ticket\.with_lock/);
  assert.match(routingJob, /PermanentRequestFailed/);
  assert.match(routingJob, /wasalx_client_route_status/);
  assert.match(routingJob, /wasalx_assignment_revision/u);
  assert.match(routingJob, /acknowledgement\['acknowledged'\] == true/u);
  assert.match(routingJob, /\[true, false\]\.include\?\(acknowledgement\['duplicate'\]\)/u);
  const routingPayloadKeys = routingJob.match(/ROUTING_PAYLOAD_KEYS = %w\[[\s\S]*?\]\.sort\.freeze/u)?.[0] ?? "";
  assert.doesNotMatch(routingPayloadKeys, /body|subject|attachment|message_id|to:|cc:/);
  assert.match(deliver, /idempotency_key/);
  assert.match(deliver, /agent: agent_identity/);
  assert.match(deliver, /attachments: attachments/);
  assert.match(deliver, /scope: 'zammad:outbound',[\s\S]*actor: agent_actor/);
  assert.match(deliver, /user\.group_ids_access\('read'\)/);
  assert.match(deliver, /article\.in_reply_to/);
  const replyContext = content(value, "app/services/service/ticket/wasalx_reply_context.rb");
  assert.match(replyContext, /find_by\(ticket_id: ticket\.id, message_id: requested\)/);
  assert.match(deliver, /WasalxReplyContext\.article_id/);
  assert.match(deliver, /WasalxReplyContext\.agent_identity/);
  assert.match(deliver, /reply_to_article_id: reply_to_article_id,[\s\S]*\}\.compact/u);
  assert.match(replyContext, /wasalx-article:/);
  assert.match(replyContext, /source\.ticket_id != ticket\.id/);
  assert.match(deliver, /Provider-origin WasalX articles are not communicative/);
  assert.doesNotMatch(initializer, /EnqueueCommunicateWhatsappJob/);
});

test("package preview uses native ticket authorization, shared target validation, and supported composer hooks", async () => {
  const value = await builtPackage();
  const controller = content(value, "app/controllers/api/v1/wasalx_controller.rb");
  const route = content(value, "config/routes/wasalx.rb");
  const preview = content(value, "lib/wasalx/reply_preview.rb");
  assert.match(route, /post '\/api\/v1\/wasalx\/tickets\/:ticket_id\/reply-preview'/u);
  assert.match(controller, /authorize!\(ticket, :agent_update_access\?\)/u);
  assert.match(preview, /TicketPolicy.new\(@actor, ticket\).agent_update_access\?/u);
  assert.match(preview, /input\[:internal\] != false/u);
  assert.match(preview, /WasalxReplyContext\.article_id/u);
  assert.match(preview, /WasalxReplyContext\.agent_identity/u);
  assert.match(preview, /scope: 'zammad:outbound', actor: Wasalx::GroupWorkspace\.actor_claims\(@actor\)/u);
  assert.doesNotMatch(preview, /create!|update!|save!|perform_later|skip_before_action/u);
  const helper = content(value, "app/frontend/shared/entities/ticket-article/action/wasalxReplyPreview.ts");
  assert.match(helper, /has_attachments: Array\.isArray/u);
  assert.match(helper, /credentials: 'same-origin'/u);
  assert.match(helper, /X-CSRF-Token/u);
  const plugin = content(value, "app/frontend/shared/entities/ticket-article/action/plugins/wasalx.ts");
  assert.match(plugin, /onOpened: prepareWasalxComposer,/u);
  assert.match(plugin, /onSelected: prepareWasalxComposer,/u);
  const prepareComposer = plugin.match(/const prepareWasalxComposer:[\s\S]*?\n\}/u)?.[0] ?? "";
  assert.match(prepareComposer, /attachWasalxReplyPreview\(ticket, body, form\)/u);
  assert.match(plugin, /onDeselected:.*detachWasalxReplyPreview/u);
  const migration = content(value, "db/addon/wasalx/202610050016_sync_wasalx_reply_preview_translations.rb");
  assert.match(migration, /Translation\.sync_locale_from_po\('ar'\)/u);
});

test("package client classifies retries, verifies TLS, and signs short-lived service JWTs", async () => {
  const value = await builtPackage();
  const client = content(value, "lib/wasalx/client.rb");
  assert.match(client, /TemporaryRequestFailed/);
  assert.match(client, /PermanentRequestFailed/);
  assert.match(client, /\[408, 425, 429\]/);
  assert.match(client, /VERIFY_PEER/);
  assert.match(client, /exp: now \+ 120/);
  assert.match(client, /def self\.get/);
  assert.match(client, /def self\.download/);
  assert.match(client, /WasalX media redirect was rejected/);
  assert.match(client, /request\['Accept-Encoding'\] = 'identity'/);
  assert.match(client, /response\.read_body do \|chunk\|/);
  assert.match(client, /data\.bytesize \+ chunk\.bytesize > maximum_bytes/);
  assert.match(client, /Net::HTTP::Get/);
  assert.match(client, /zammad_user_id/);
  assert.match(client, /value\.bytesize > 7_000/);
  assert.match(client, /json\.bytesize > 128_000/);
  assert.match(client, /Zlib::Deflate\.deflate/);
  assert.match(client, /X-Wasalx-Zammad-Groups/);
  assert.match(client, /zammad_group_ids_sha256/);
  assert.match(client, /http_body_sha256/);
  assert.match(client, /zammad_group_admin/);
  assert.doesNotMatch(client, /WASALX_SERVICE_JWT_SECRET['"]?\s*[:=]\s*['"][^E]/);
});

test("supported frontend plugin surfaces provide a premium, recoverable WasalX agent experience", async () => {
  const value = await builtPackage();
  const sidebarPlugin = content(value, "app/frontend/apps/desktop/pages/ticket/components/TicketSidebar/plugins/wasalx.ts");
  const sidebar = [
    content(value, "app/frontend/shared/components/WasalxTicketOperations/WasalxTicketOperations.vue"),
    content(value, "app/frontend/shared/components/WasalxTicketOperations/useWasalxTicketOperations.ts"),
  ].join("\n");
  const articlePlugin = content(value, "app/frontend/shared/entities/ticket-article/action/plugins/wasalx.ts");
  const controller = content(value, "app/controllers/api/v1/wasalx_controller.rb");
  const routes = content(value, "config/routes/wasalx.rb");
  const panel = content(value, "app/services/service/ticket/wasalx_panel.rb");
  const concern = content(value, "app/models/ticket/article/enqueue_communicate_wasalx_job.rb");
  const groupRoutes = content(value, "app/frontend/apps/desktop/pages/wasalx-groups/routes.ts");
  const groupWorkspace = content(value, "app/frontend/apps/desktop/pages/wasalx-groups/views/WasalxGroups.vue");

  assert.match(sidebarPlugin, /TicketSidebarScreenType\.TicketDetailView/);
  assert.match(sidebarPlugin, /permissions: \['ticket\.agent'\]/);
  assert.match(sidebarPlugin, /icon: 'whatsapp'/);
  assert.match(sidebar, /data-test-id="wasalx-ticket-panel"/);
  assert.match(sidebar, /WasalX status is unavailable/);
  assert.match(sidebar, /Retry status check/);
  assert.match(sidebar, /Open in WasalX/);
  assert.match(sidebar, /Show triggering message/);
  assert.match(sidebar, /message_context\.group_id/);
  assert.match(sidebar, /rel="noopener noreferrer"/);
  assert.match(sidebar, /aria-busy="true"/);
  assert.match(sidebar, /connection\.available/);
  assert.match(sidebar, /We could not verify this WhatsApp connection/);
  assert.match(sidebar, /Delivery could not be confirmed\. Check the WhatsApp group/);
  assert.match(sidebar, /data-test-id="wasalx-delivery-retry"/);
  assert.match(sidebar, /Type RETRY to confirm/);
  assert.match(sidebar, /retryPhase === 'pending'/);
  assert.match(sidebar, /delivery\.retry_allowed/);
  assert.match(sidebar, /delivery\.article_id/);
  assert.match(sidebar, /globalThis\.crypto\.randomUUID\(\)/);
  assert.doesNotMatch(sidebar, /Connection checked|Administrative access is available/u);
  assert.doesNotMatch(sidebar, /#[0-9a-f]{3,8}\b/i);

  assert.match(articlePlugin, /value: ARTICLE_TYPE/);
  assert.match(articlePlugin, /label: __\('Reply on WhatsApp'\)/);
  assert.match(articlePlugin, /label: __\('WhatsApp'\)/);
  assert.match(articlePlugin, /buttonLabel: __\('Send on WhatsApp'\)/);
  assert.doesNotMatch(articlePlugin, /Reply to group|WasalX group|Send to WhatsApp group/);
  assert.match(articlePlugin, /icon: 'whatsapp'/);
  assert.match(articlePlugin, /internal: false/);
  assert.match(articlePlugin, /EnumTicketArticleSenderName\.Customer/);
  assert.match(articlePlugin, /inReplyTo: replyIdentity\(currentArticle\)/);
  assert.match(articlePlugin, /getAcceptableFileTypesString\(allowedFiles\)/);
  assert.match(articlePlugin, /accept: acceptableFileTypes/);
  assert.match(articlePlugin, /size: 25 \* 1024 \* 1024/);
  assert.match(articlePlugin, /length:1,4096/);
  assert.match(articlePlugin, /maxlength: 4096/);
  assert.match(articlePlugin, /wasalx_connection_id/);
  assert.match(articlePlugin, /wasalx_group_id/);
  assert.doesNotMatch(articlePlugin, /internal: true/);

  assert.match(controller, /authorize!\(ticket, :agent_read_access\?\)/);
  assert.match(controller, /WasalxPanel\.new\(ticket: ticket, current_user: current_user\)\.execute/u);
  assert.match(routes, /get '\/api\/v1\/wasalx\/tickets\/:ticket_id\/panel'/);
  assert.match(panel, /scope: 'zammad:context'/);
  assert.match(panel, /connection_state: 'UNAVAILABLE'/);
  assert.match(panel, /URI::HTTPS/);
  assert.match(panel, /def initialize\(ticket:, current_user:\)/u);
  assert.match(concern, /before_create :ticket_article_preflight_wasalx_outbound/);
  assert.match(concern, /\/internal\/v1\/zammad\/outbound\/preflight/);
  assert.match(concern, /errors\.add\(:base/);
  assert.doesNotMatch(panel, /message_body|secret_reference|phone_e164/);

  assert.match(groupRoutes, /path: '\/wasalx\/groups'/);
  assert.match(groupRoutes, /requiredPermission: \['ticket\.agent'\]/);
  assert.match(groupRoutes, /level: 1/);
  assert.match(groupWorkspace, /My Groups/);
  assert.match(groupWorkspace, /My Team/);
  assert.match(groupWorkspace, /All Accessible/);
  assert.match(groupWorkspace, /document\.visibilityState !== 'visible'/);
  assert.match(groupWorkspace, /Show linked message/);
  assert.match(groupWorkspace, /linkedMessageContext/);
  assert.match(groupWorkspace, /line-clamp-2 break-words text-sm/);
  assert.match(groupWorkspace, /inline-flex min-h-8 items-center/);
  assert.match(groupWorkspace, /showMissingSenderIdentity/);
  assert.match(groupWorkspace, /#article-\$\{ticket\.links\[0\]\.article_id\}/);
  assert.match(groupWorkspace, /History starts when capture is enabled/);
  assert.match(groupWorkspace, /reply_to_message_id/);
  assert.match(groupWorkspace, /request_token: requestToken/);
  assert.match(groupWorkspace, /retryableSend/);
  assert.match(groupWorkspace, /Create a ticket from this message/);
  assert.match(groupWorkspace, /Link this message to a ticket/);
  assert.match(groupWorkspace, /group_workspace\/ticket_groups/);
  assert.match(groupWorkspace, /group_workspace\/groups\/\$\{groupId\}\/participants/);
  assert.match(groupWorkspace, /participant\.phone\?\.match/);
  assert.match(groupWorkspace, /selectedMentionTokens/u);
  assert.match(groupWorkspace, /role="combobox"/);
  assert.match(groupWorkspace, /role="listbox"/);
  assert.match(groupWorkspace, /tabindex="-1"/);
  assert.match(groupWorkspace, /@blur="closeMentions"/);
  assert.match(groupWorkspace, /Skip to message composer/);
  assert.match(groupWorkspace, /Intl\.NumberFormat\(document\.documentElement\.lang/u);
  assert.match(groupWorkspace, /mentions/);
  assert.match(groupWorkspace, /target_group_id/);
  assert.match(groupWorkspace, /ticket_number/);
  assert.match(groupWorkspace, /loadConversation\(selectedGroupId\.value, true, refreshSupportingData\)/);
  assert.match(groupWorkspace, /4_500 \+ Math\.floor\(Math\.random\(\) \* 1_501\)/u);
  assert.doesNotMatch(groupWorkspace, /setInterval/u);
  assert.match(groupWorkspace, /media_capabilities/);
  assert.match(groupWorkspace, /:accept="acceptedMediaTypes"/);
  assert.match(groupWorkspace, /voiceRecordingAvailable/);
  assert.doesNotMatch(groupWorkspace, /const ACCEPTED_MEDIA|accept="image\/png/);
  assert.match(groupWorkspace, /dir="auto"/);
  assert.match(groupWorkspace, /text-blue-900/);
  assert.match(groupWorkspace, /variant="submit"/);
  assert.doesNotMatch(groupWorkspace, /(?:text|bg|outline)-blue-800|text-stone-200/);
  assert.doesNotMatch(groupWorkspace, /#[0-9a-f]{3,8}\b/i);

  // Drop-in files live only in Zammad's auto-discovered plugin directories.
  // The package never replaces the registries, icon map, or native WhatsApp implementation.
  for (const forbidden of [
    "app/frontend/apps/desktop/pages/ticket/components/TicketSidebar/plugins/index.ts",
    "app/frontend/apps/desktop/pages/ticket/components/TicketSidebar/plugins/types.ts",
    "app/frontend/shared/entities/ticket-article/action/plugins/index.ts",
    "app/frontend/shared/entities/ticket-article/composables/channelIconsMap.json",
    "app/frontend/apps/desktop/router/index.ts",
    "app/frontend/apps/desktop/components/PageNavigation/firstLevelRoutes.ts",
  ]) assert.ok(!value.files.some((file) => file.location === forbidden), `forbidden core override ${forbidden}`);
});






test("sanitized compatibility packages retain their exact metadata", () => {
  assert.deepEqual(compatibility, {
  "schemaVersion": 1,
  "artifacts": {
    "0.5.36": {
      "path": "build/zammad/wasalx-0.5.36.zpm",
      "mode": "100644",
      "sha256": "837436d8f81c7e7df82683e52274ee76794261d5155411ea4728d9dd9071e0f2",
      "provenance": "sanitized compatibility fixture; not the immutable historical release artifact"
    },
    "0.5.13": {
      "path": "build/zammad/wasalx-0.5.13.zpm",
      "mode": "100644",
      "sha256": "56e7e165adf1700cd277587a62f2a4a6544eb256b35feef34fe45a1b24d2fd4d",
      "provenance": "sanitized compatibility fixture; not the immutable historical release artifact"
    }
  }
});
});

test("the package installer preserves additive migrations while replacing a newer artifact during rollback", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-package-install-contract.rb")], {
    cwd: workspace,
    encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

test("the package sanitizes native internal errors through supported local translations", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-internal-error-translation-contract.rb")], {
    cwd: workspace,
    encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

test("every package Ruby source parses", async () => {
  for (const file of await rubyFiles(path.join(workspace, "zammad-package"))) {
    const result = spawnSync("ruby", ["-c", file], { encoding: "utf8" });
    assert.ifError(result.error);
    assert.equal(result.status, 0, `${file}: ${result.stderr || result.stdout}`);
  }
});

test("the package controller authenticates before ticket-scoped authorization", async () => {
  const value = await builtPackage();
  const controller = content(value, "app/controllers/api/v1/wasalx_controller.rb");
  const groupService = content(value, "lib/wasalx/group_workspace.rb");
  const identifiers = content(value, "lib/wasalx/native_identifiers.rb");
  assert.match(controller, /prepend_before_action :authentication_check/u);
  assert.doesNotMatch(controller, /prepend_before_action :authenticate_and_authorize!/u);
  assert.match(controller, /authorize!\(ticket, :agent_read_access\?\)/u);
  assert.match(controller, /authorize!\(ticket, :agent_update_access\?\)/u);
  assert.match(controller, /current_user\.permissions\?\('ticket\.agent\.wasalx_retry'\)/u);
  assert.match(controller, /instance_id: ENV\.fetch\('WASALX_ZAMMAD_INSTANCE_ID'\)/u);
  assert.match(controller, /delivery_id: delivery_id/u);
  assert.match(controller, /confirm_outcome_unknown/u);
  assert.match(groupService, /actor\.group_ids_access\('read'\)/u);
  assert.match(groupService, /TicketPolicy\.new\(@actor, ticket\)\.agent_read_access\?/u);
  assert.match(groupService, /scope: 'zammad:groups'/u);
  assert.match(identifiers, /def bounded_limit!/u);
  assert.match(controller, /request_token/u);
  assert.match(groupService, /Outbound group messages cannot be linked to a customer ticket article/u);
  assert.match(controller, /def group_workspace_send/u);
  assert.match(groupService, /attachments\(created_by_id: @actor\.id\)\.index_by \{ \|item\| item\.id\.to_s \}/u);
  assert.match(controller, /def group_workspace_participants/u);
  assert.match(groupService, /def group_mentions!/u);
  assert.doesNotMatch(groupService, /Mentioned participants must appear in the message/u);
  assert.match(groupService, /s\\\.whatsapp\\\.net\|lid/u);
  assert.match(controller, /def group_workspace_create_ticket/u);
  assert.match(groupService, /def group_message_customer/u);
  assert.match(groupService, /Digest::SHA256\.hexdigest/u);
  assert.match(controller, /def group_workspace_link_ticket/u);
  assert.match(groupService, /authorize_ticket!\(ticket, :create\?\)/u);
  assert.match(controller, /authorize!\(ticket, :agent_update_access\?\)/u);
  assert.match(groupService, /wasalx_operation_key/u);
  assert.match(groupService, /Transaction\.execute/u);
  assert.match(groupService, /wasalx_origin: 'provider'/u);
  assert.match(groupService, /group-link:#\{article\.ticket_id\}:#\{message_id\}/u);
  assert.match(groupService, /agentDisplayName: @actor\.fullname/u);
  assert.match(groupService, /group-workspace:#\{@actor\.id\}:#\{request_token\}/u);
  assert.match(controller, /Wasalx::ServiceIdentity\.authorize!\(current_user, @_token\)/u);
  const serviceAuthorization = /def ensure_group_service!([\s\S]*?)\n {2}end/u.exec(controller)?.[1] ?? "";
  assert.doesNotMatch(serviceAuthorization, /permissions\?\('admin'\)/u);
  assert.match(controller, /group_workspace_upload_store\(lock: true\)/u);
  assert.match(controller, /store\.touch/u);
  assert.doesNotMatch(controller, /authorization_check/u);
});

test("executable Ruby contract proves filtering, idempotency, media, identity, and failure visibility", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-runtime-contract.rb")], {
    cwd: workspace,
    encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

test("executable Ruby agent-panel contract proves authorization, health truthfulness, and safe recovery", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-agent-panel-contract.rb")], {
    cwd: workspace,
    encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

test("executable Ruby membership contract proves immutable identity and stale-session denial", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-membership-contract.rb")], {
    cwd: workspace,
    encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

test("executable Ruby session assurance contract proves verified claims and exact native sessions", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-session-assurance-contract.rb")], {
    cwd: workspace,
    encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

test("executable Ruby routing configuration contract proves scoped authority, CAS and native drift", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-routing-configuration-contract.rb")], {
    cwd: workspace,
    encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

test("migrations create the channel contract and upgrade-safe routing metadata", async () => {
  const value = await builtPackage();
  for (const file of value.files.filter(({ location }) => location.startsWith("db/addon/wasalx/"))) {
    const className = file.location
      .split("/")
      .at(-1)!
      .replace(/^\d+_|\.rb$/gu, "")
      .split("_")
      .map((part) => part[0]!.toUpperCase() + part.slice(1))
      .join("");
    assert.match(content(value, file.location), new RegExp(`class ${className}\\b`, "u"));
  }
  const migration = content(value, "db/addon/wasalx/202608090001_create_wasalx_channel.rb");
  const routingMigration = content(value, "db/addon/wasalx/202608090002_add_wasalx_routing_attributes.rb");
  const materializationMigration = content(
    value,
    "db/addon/wasalx/202608110003_materialize_wasalx_ticket_attributes.rb",
  );
  const clientRoutingMigration = content(value, "db/addon/wasalx/202608150004_add_client_routing_attributes.rb");
  const groupWorkspaceOperationMigration = content(value, "db/addon/wasalx/202608200005_add_group_workspace_operation_key.rb");
  const uploadCleanupMigration = content(value, "db/addon/wasalx/202608230006_schedule_group_workspace_upload_cleanup.rb");
  const modernDesktopMigration = content(value, "db/addon/wasalx/202608240008_enable_wasalx_modern_desktop_ui.rb");
  const directConversationMigration = content(value, "db/addon/wasalx/202608300010_add_direct_conversation_state.rb");
  const clientRoutingMaterialization = content(value, "db/addon/wasalx/202609010012_materialize_wasalx_client_routing_attributes.rb");
  const hiddenClientRoutingMigration = content(value, "db/addon/wasalx/202609020014_hide_wasalx_client_routing_attributes.rb");
  const assignmentRevisionMigration = content(value, "db/addon/wasalx/202609020015_add_wasalx_assignment_revision.rb");
  const uploadCleanupJob = content(value, "app/jobs/wasalx_group_workspace_upload_cleanup_job.rb");
  assert.match(migration, /communication: true/);
  assert.match(migration, /ticket\.agent\.wasalx_retry/);
  assert.match(migration, /label: 'WasalX delivery retry'/);
  assert.match(migration, /description: 'Retry failed WasalX deliveries'/);
  assert.doesNotMatch(migration, /\bnote:/);
  for (const field of ["wasalx_reference", "wasalx_group_id", "wasalx_connection_id", "wasalx_delivery_status"])
    assert.match(migration, new RegExp(field));
  for (const field of ["wasalx_assignment_mode", "wasalx_default_priority", "wasalx_sla_policy_id", "wasalx_business_hours_mode", "wasalx_business_hours_calendar_id"])
    assert.match(routingMigration, new RegExp(field));
  assert.match(materializationMigration, /ActiveRecord::Migration\.add_column/u);
  assert.match(materializationMigration, /Ticket\.reset_column_information/u);
  assert.match(materializationMigration, /WasalX ticket columns were not materialized/u);
  assert.doesNotMatch(materializationMigration, /ObjectManager::Attribute\.migration_execute/u);
  for (const field of ["wasalx_client_routing_version_id", "wasalx_client_id", "wasalx_client_route_status", "wasalx_client_route_matched_by"])
    assert.match(clientRoutingMigration, new RegExp(field));
  assert.match(clientRoutingMaterialization, /ActiveRecord::Migration\.add_column/u);
  assert.match(clientRoutingMaterialization, /Ticket\.reset_column_information/u);
  assert.match(clientRoutingMaterialization, /def self\.down; end/u);
  for (const field of ["wasalx_client_routing_version_id", "wasalx_client_id", "wasalx_client_route_status", "wasalx_client_route_matched_by"])
    assert.match(hiddenClientRoutingMigration, new RegExp(field));
  assert.match(hiddenClientRoutingMigration, /active: false/u);
  assert.match(hiddenClientRoutingMigration, /editable: false/u);
  assert.match(hiddenClientRoutingMigration, /shown: false/u);
  assert.match(hiddenClientRoutingMigration, /ObjectManager::Attribute\.transaction/u);
  assert.match(hiddenClientRoutingMigration, /attribute_to_references_hash/u);
  assert.match(hiddenClientRoutingMigration, /attribute_used_by_references\?\('Ticket', name, references\)/u);
  assert.ok(hiddenClientRoutingMigration.indexOf("raise \"Referenced WasalX client-routing attributes")
    < hiddenClientRoutingMigration.indexOf("attribute.update!"));
  for (const flag of ["to_create", "to_migrate", "to_delete", "to_config"])
    assert.match(hiddenClientRoutingMigration, new RegExp(`${flag}: false`, "u"));
  assert.match(hiddenClientRoutingMigration, /def self\.down; end/u);
  assert.match(assignmentRevisionMigration, /wasalx_assignment_revision/u);
  assert.match(assignmentRevisionMigration, /:bigint, null: false, default: 0/u);
  assert.match(assignmentRevisionMigration, /NEW\.group_id IS DISTINCT FROM OLD\.group_id/u);
  assert.match(assignmentRevisionMigration, /NEW\.owner_id IS DISTINCT FROM OLD\.owner_id/u);
  assert.match(assignmentRevisionMigration, /OLD\.wasalx_assignment_revision \+ 1/u);
  assert.match(assignmentRevisionMigration, /BEFORE UPDATE OF group_id, owner_id, wasalx_assignment_revision/u);
  assert.doesNotMatch(assignmentRevisionMigration, /ObjectManager::Attribute/u);
  assert.match(groupWorkspaceOperationMigration, /wasalx_operation_key/u);
  assert.match(groupWorkspaceOperationMigration, /unique: true/u);
  assert.match(groupWorkspaceOperationMigration, /where: 'wasalx_operation_key IS NOT NULL'/u);
  assert.match(groupWorkspaceOperationMigration, /def self\.down; end/u);
  assert.match(uploadCleanupMigration, /WasalxGroupWorkspaceUploadCleanupJob\.perform_now/u);
  assert.match(uploadCleanupMigration, /period: 1\.day/u);
  assert.match(uploadCleanupMigration, /active: false/u);
  assert.match(uploadCleanupJob, /RETENTION = 7\.days/u);
  assert.match(uploadCleanupJob, /Store::Object\.lookup\(name: OBJECT_NAME\)/u);
  assert.match(uploadCleanupJob, /Store\.lock\.find_by/u);
  assert.match(uploadCleanupJob, /store\.updated_at >= cutoff/u);
  assert.match(uploadCleanupJob, /Store\.remove_item\(store\.id\)/u);
  assert.match(modernDesktopMigration, /'ui_desktop_beta_switch' => false/u);
  assert.match(modernDesktopMigration, /'ui_desktop_beta_switch_role_ids' => \[\]/u);
  assert.match(modernDesktopMigration, /Setting\.set\(name, value\)/u);
  assert.match(modernDesktopMigration, /def self\.down; end/u);
  for (const field of ["wasalx_bot_conversation", "wasalx_bot_state"])
    assert.match(directConversationMigration, new RegExp(field));
  assert.match(directConversationMigration, /ActiveRecord::Migration\.add_column/u);
  assert.match(directConversationMigration, /shown: false/u);
  for (const field of [
    "wasalx_reference",
    "wasalx_group_id",
    "wasalx_group_name",
    "wasalx_connection_id",
    "wasalx_provider",
    "wasalx_source_message_id",
    "wasalx_correlation_key",
    "wasalx_latest_external_message_id",
    "wasalx_rule_version",
    "wasalx_correlation_status",
    "wasalx_delivery_status",
    "wasalx_assignment_mode",
    "wasalx_default_priority",
    "wasalx_sla_policy_id",
    "wasalx_business_hours_mode",
    "wasalx_business_hours_calendar_id",
  ]) assert.match(materializationMigration, new RegExp(field));
});


test("native mobile package route preserves authorization, shared workspace and native ticket destinations", async () => {
  const value = await builtPackage();
  const route = content(value, "app/frontend/apps/mobile/pages/wasalx-groups/routes.ts");
  const workspace = content(value, "app/frontend/apps/desktop/pages/wasalx-groups/views/WasalxGroups.vue");
  assert.match(route, /path: '\/wasalx\/groups'/);
  assert.match(route, /requiredPermission: \['ticket\.agent'\]/);
  assert.match(route, /requiresAuth: true/);
  assert.match(route, /props: \{ mobile: true \}/);
  assert.match(route, /#desktop\/pages\/wasalx-groups\/views\/WasalxGroups\.vue/);
  assert.match(workspace, /mobile: false/);
  assert.match(workspace, /props\.mobile \? 'div' : LayoutContent/);
  assert.doesNotMatch(workspace, /["'`]\/desktop\/tickets\//);
  assert.match(workspace, /\/tickets\/\$\{ticket/);
});


test("native mobile group loaders use the mobile icon contract", async () => {
  const value = await builtPackage();
  const workspace = content(value, "app/frontend/apps/desktop/pages/wasalx-groups/views/WasalxGroups.vue");
  assert.match(workspace, /import MobileLoader from '#mobile\/components\/CommonLoader\/CommonLoader\.vue'/);
  assert.match(workspace, /props\.mobile \? MobileLoader : DesktopLoader/);
  assert.match(workspace, /props\.mobile \? \{ position: 'center' as const \} : \{ size: 'large' as const \}/);
  assert.equal((workspace.match(/:is="groupLoader"/g) ?? []).length, 2);
});


test("mobile ticket operations and reciprocal navigation use native package seams", async () => {
  const value = await builtPackage();
  const plugin = content(value, "app/frontend/apps/mobile/pages/ticket/views/TicketInformation/plugins/wasalx.ts");
  const mobile = content(value, "app/frontend/apps/mobile/pages/ticket/views/TicketInformation/TicketInformationWasalx.vue");
  const desktop = content(value, "app/frontend/apps/desktop/pages/ticket/components/TicketSidebar/TicketSidebarWasalx/TicketSidebarWasalx.vue");
  assert.match(plugin, /requiredPermission: \['ticket\.agent'\]/);
  assert.match(plugin, /component: \(\) => import/);
  assert.doesNotMatch(plugin, /redirect:/);
  for (const source of [desktop, mobile]) assert.match(source, /WasalxTicketOperations/);
  assert.match(mobile, /useTicketInformation/);
  assert.match(mobile, /ticket\.value\?\.internalId/);
  assert.match(mobile, /to="\/wasalx\/groups"/);
  for (const [name, target] of [["wasalx-mobile", "/mobile/"], ["wasalx-mobile-groups", "/mobile/wasalx/groups"]]) {
    const menu = content(value, `app/frontend/apps/desktop/components/layout/LayoutSidebar/LeftSidebar/AvatarMenu/plugins/${name}.ts`);
    assert.match(menu, /useForceDesktop/);
    assert.match(menu, /forceDesktopLocalStorage\.value = false/);
    assert.ok(menu.includes(`window.location.assign('${target}')`));
    assert.match(menu, /permission: 'ticket\.agent'/);
    assert.doesNotMatch(menu, /localStorage\.clear|fetch\(/);
  }
});

test("executable Ruby machine identity contract proves exact scopes and noninteractive lifecycle", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-service-identity-contract.rb")], { cwd: workspace, encoding: "utf8" });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors, 0 skips/);
});


test("shared group workspace preserves human attribution and group boundaries", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-group-workspace-service-contract.rb")], {
    cwd: workspace,
    encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

test("native email branding preserves default guards, customization and backend health", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-portal-mail-contract.rb")], {
    cwd: workspace, encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

test("portal email admission requires the exact active native mailbox", () => {
  const result = spawnSync("ruby", [path.join(workspace, "tests/zammad-portal-email-sender-contract.rb")], {
    cwd: workspace, encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /0 failures, 0 errors/);
});

for (const file of ["portal-groups-contract.rb", "portal-upload-expiry-test.rb", "zammad-mailbox-storage-contract.rb", "zammad-mailbox-initializer-contract.rb"]) {
  test(`executable portal contract: ${file}`, () => {
    const result = spawnSync("ruby", [path.join(workspace, "tests", file)], { cwd: workspace, encoding: "utf8", timeout: 15_000 });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /0 failures, 0 errors, 0 skips/);
  });
}

test("portal package includes complete administration, group and upload runtime boundaries", async () => {
  const value = await builtPackage();
  const locations = new Set(value.files.map(file => file.location));
  for (const location of [
    "app/models/wasalx_admin_operation.rb", "lib/wasalx/portal_team_administration.rb",
    "lib/wasalx/portal_mailbox_administration.rb", "lib/wasalx/mailbox_verification.rb",
    "lib/wasalx/mailbox_address_draft.rb", "lib/wasalx/required_smtp_tls.rb",
    "app/models/wasalx/mailbox_verification_smtp.rb",
    "lib/wasalx/portal_groups.rb", "lib/wasalx/group_workspace.rb",
    "lib/wasalx/portal_workspace_uploads.rb", "lib/wasalx/portal_upload_expiry.rb",
    "config/initializers/wasalx_mailbox_administration.rb", "config/initializers/wasalx_portal_mail.rb",
    "db/addon/wasalx/202610180003_add_wasalx_admin_operations.rb",
    "db/addon/wasalx/202610180004_schedule_portal_upload_expiry.rb",
    "db/addon/wasalx/202610180006_reconcile_wasalx_mail_defaults.rb",
  ]) assert.ok(locations.has(location), `Missing runtime package source: ${location}`);
});
