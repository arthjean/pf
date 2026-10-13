// Workflow's real World types fit `world()`. Checked only when the Worlds
// libpf bundles are installed (`npm ci --prefix sdk/durable`).
import type { World as WorkflowWorld } from "@workflow/world";
import { createWorld as createLocalWorld } from "@workflow/world-local";
import { createWorld as createVercelWorld } from "@workflow/world-vercel";
import { createPfAgent } from "libpf";
import { world, type World } from "libpf/durable-world";

declare const any: WorkflowWorld;
export const structural: World = any;

export async function run(): Promise<void> {
  const sessions = createLocalWorld({ dataDir: ".pf/sessions" });
  await sessions.start?.();
  const agent = createPfAgent({ durability: world(sessions) });
  await agent.close();
  await sessions.close?.();

  createPfAgent({ durability: world(() => createVercelWorld(), { name: "vercel", queueDurable: true }) });
  createPfAgent({ durability: world(async () => createLocalWorld(), { livenessKnown: true, alive: () => null }) });
}
