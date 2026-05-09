import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Lane B test runner. Uses Cloudflare's vitest worker plugin so Durable
// Objects, env bindings, and `fetch` against the worker entry point all
// behave identically to a real `wrangler dev` deploy. Pure type-only
// tests (e.g. wire schema) still run inside the same plugin — no
// separate node-mode config needed.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
