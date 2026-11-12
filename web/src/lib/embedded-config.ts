import { normalizeLocalChannels, type AiConfig } from "@/stores/use-config-store";

export function resolveEmbeddedConfig(config: AiConfig, baseUrl: string | null, apiKey: string | null) {
    const first = normalizeLocalChannels(config)[0];
    const channel = {
        ...first,
        name: "易拓 AI",
        baseUrl: baseUrl || first.baseUrl,
        apiKey: apiKey || first.apiKey,
    };
    return {
        channelMode: "local" as const,
        baseUrl: channel.baseUrl,
        apiKey: channel.apiKey,
        localChannels: [channel, ...normalizeLocalChannels(config).slice(1)],
        activeChannelId: channel.id,
        imageChannelId: channel.id,
        videoChannelId: channel.id,
        textChannelId: channel.id,
        audioChannelId: channel.id,
    };
}
