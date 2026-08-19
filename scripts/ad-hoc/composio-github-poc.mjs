#!/usr/bin/env node
/**
 * Composio proof-of-concept: connect a GitHub account via Composio-managed
 * OAuth and execute one real tool call through it.
 *
 * This is a standalone experiment (scripts/ad-hoc/) that talks to the
 * Composio API directly via the official @composio/core SDK. It is NOT
 * wired into OmniRoute's provider/executor pipeline, the MCP server, or any
 * other production code path.
 *
 * Usage:
 *   export COMPOSIO_API_KEY=ak_...        # never commit this — env var only
 *   node scripts/ad-hoc/composio-github-poc.mjs
 *
 * What it does:
 *   1. Reuses an existing Composio-managed auth config for the "github"
 *      toolkit if one already exists for this API key, otherwise creates one.
 *   2. Starts a connection request and prints a URL for you to open and
 *      approve in a browser (Composio's hosted GitHub OAuth app — no GitHub
 *      OAuth app of your own needed).
 *   3. Polls for up to 3 minutes until the connection becomes ACTIVE.
 *   4. Executes GITHUB_GET_THE_AUTHENTICATED_USER through that connection —
 *      a real call against the GitHub API via Composio, not a mock.
 */

import { Composio } from "@composio/core";

const apiKey = process.env.COMPOSIO_API_KEY;
if (!apiKey) {
  console.error(
    "Missing COMPOSIO_API_KEY.\n\n" +
      "Export it in your shell first (never paste it into chat/logs):\n" +
      "  export COMPOSIO_API_KEY=ak_...\n"
  );
  process.exit(1);
}

// Composio's per-toolkit connections are scoped to a "user id" that you
// choose (it's your own identifier, not a Composio account). Override with
// COMPOSIO_USER_ID if you want a stable id across runs.
const userId = process.env.COMPOSIO_USER_ID || "omniroute-poc-user";
const TOOLKIT = "github";

const composio = new Composio({ apiKey });

async function getOrCreateAuthConfig() {
  const existing = await composio.authConfigs.list({
    toolkit: TOOLKIT,
    isComposioManaged: true,
  });
  if (existing.items.length > 0) {
    console.log(`   reusing existing auth config: ${existing.items[0].id}`);
    return existing.items[0].id;
  }

  const created = await composio.authConfigs.create(TOOLKIT, {
    type: "use_composio_managed_auth",
    name: "GitHub (OmniRoute POC)",
  });
  console.log(`   created auth config: ${created.id}`);
  return created.id;
}

async function main() {
  console.log(`Composio POC — connecting GitHub for user "${userId}"\n`);

  console.log("1/4 Resolving auth config for the github toolkit...");
  const authConfigId = await getOrCreateAuthConfig();

  console.log("\n2/4 Starting a connection request...");
  const connectionRequest = await composio.connectedAccounts.link(userId, authConfigId);
  console.log(`   connected account id: ${connectionRequest.id}`);
  console.log(`\n   >>> Open this URL and approve access: <<<\n   ${connectionRequest.redirectUrl}\n`);

  console.log("3/4 Waiting up to 3 minutes for the connection to become ACTIVE...");
  const connectedAccount = await connectionRequest.waitForConnection(180_000);
  console.log(`   connection status: ${connectedAccount.status}`);

  console.log("\n4/4 Executing a real tool call: GITHUB_GET_THE_AUTHENTICATED_USER");
  const result = await composio.tools.execute("GITHUB_GET_THE_AUTHENTICATED_USER", {
    userId,
    connectedAccountId: connectedAccount.id,
  });

  if (!result.successful) {
    console.error("\nTool call failed:", result.error);
    process.exit(1);
  }

  const user = result.data;
  console.log("\n✅ Success — authenticated as:");
  console.log(`   login:         ${user.login}`);
  console.log(`   name:          ${user.name ?? "(none set)"}`);
  console.log(`   public_repos:  ${user.public_repos}`);
  console.log(`   html_url:      ${user.html_url}`);
}

main().catch((err) => {
  console.error("\nComposio POC failed:", err instanceof Error ? err.message : err);
  process.exit(1);
});
