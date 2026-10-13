// "libpf" under bundler resolution without the "node" condition: the
// "default" export condition, which is the browser entry.
import { createPfAgent, memory } from "libpf";
// @ts-expect-error without the "node" condition, "libpf" is the browser entry, which has no getBackendInfo()
import { getBackendInfo } from "libpf";

createPfAgent({ apiKey: "<short-lived credential>", durability: memory(), wasm: "/pf-core.wasm" });
// @ts-expect-error backend selection belongs to the Node.js entry
createPfAgent({ backend: "native" });

void getBackendInfo;
