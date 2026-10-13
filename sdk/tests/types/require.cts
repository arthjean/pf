// CommonJS: `require("libpf")` loads the generated node.cjs entry.
import libpf = require("libpf");
import nodeEntry = require("libpf/node");

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
function assertType<T extends true>(): void {}

const agent: libpf.PfAgent = libpf.createPfAgent({ model: "anthropic/claude-haiku-4.5" });
const turn = agent.session().prompt("Explain this project.");

export async function run(): Promise<void> {
  const result = await turn.result;
  assertType<Equal<typeof result, libpf.PfTurnResult>>();

  // The ESM durabilities work with the CommonJS agent: one Durability type.
  const { local } = await import("libpf/durable-local");
  const { world } = await import("libpf/durable-world");
  libpf.createPfAgent({ durability: local({ dir: ".pf/sessions" }) });
  libpf.createPfAgent({ durability: libpf.memory() });
  void world;

  const engine = await nodeEntry.createPfEngine({ apiKey: "key", persistence: libpf.createMemoryPersistence() });
  for (let open = engine.resume(); open; open = engine.resume()) await open.result;

  const info = await libpf.getBackendInfo({ backend: "native" });
  console.log(info.backend, libpf.libpfApiVersion, await libpf.listModels({ apiKey: "key" }));

  try {
    await engine.close();
  } catch (error) {
    if (error instanceof libpf.PfFencedError) assertType<Equal<typeof error.code, "PF_FENCED">>();
    if (error instanceof nodeEntry.PfJournalVersionError) assertType<Equal<typeof error.code, "PF_JOURNAL_VERSION">>();
  }

  // @ts-expect-error null is not a session id
  agent.session(null);
}
