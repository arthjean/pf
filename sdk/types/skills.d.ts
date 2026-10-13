// `libpf/skills` (skills.js): instructions and tools from already-loaded
// skill records.
import type { PfTool } from "./libpf.cjs";

/** A resource whose text joins its skill's instructions. */
export interface SkillResource {
  uri: string;
  text: string;
}

/** An already-loaded skill. */
export interface SkillRecord {
  name: string;
  instructions: string;
  description?: string;
  resources?: readonly SkillResource[];
  tools?: readonly PfTool[];
}

/** What `createSkillsAdapter()` returns: spread it into the agent options. */
export interface SkillsAdapter {
  instructions: string;
  tools: PfTool[];
}

/** Turns up to 64 skill records into instructions and tools. */
export declare function createSkillsAdapter(records: readonly SkillRecord[]): SkillsAdapter;
