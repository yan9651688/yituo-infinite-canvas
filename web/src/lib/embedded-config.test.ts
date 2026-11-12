import { describe, expect, it } from "bun:test";
import { resolveEmbeddedConfig } from "./embedded-config";
import { defaultConfig } from "@/stores/use-config-store";

describe("resolveEmbeddedConfig", () => {
    it("更新已有默认渠道，避免嵌入后继续沿用旧地址和密钥", () => {
        const config = {
            ...defaultConfig,
            localChannels: [{ id: "local-default", protocol: "openai" as const, name: "旧渠道", baseUrl: "https://old.example", apiKey: "old-key", models: ["gpt-image-2"] }],
        };
        const result = resolveEmbeddedConfig(config, "https://www.yituohub.si", "sk-new");
        expect(result.baseUrl).toBe("https://www.yituohub.si");
        expect(result.apiKey).toBe("sk-new");
        expect(result.localChannels[0]).toMatchObject({ id: "local-default", name: "易拓 AI", baseUrl: "https://www.yituohub.si", apiKey: "sk-new", models: ["gpt-image-2"] });
        expect(result.imageChannelId).toBe("local-default");
        expect(result.videoChannelId).toBe("local-default");
        expect(result.textChannelId).toBe("local-default");
    });

    it("没有本地渠道时创建易拓直连渠道", () => {
        const result = resolveEmbeddedConfig(defaultConfig, "https://www.yituohub.si", "sk-new");
        expect(result.localChannels).toHaveLength(1);
        expect(result.localChannels[0].protocol).toBe("openai");
        expect(result.localChannels[0].baseUrl).toBe("https://www.yituohub.si");
        expect(result.localChannels[0].apiKey).toBe("sk-new");
    });
});
