export const APP_VERSION = process.env.NEXT_PUBLIC_APP_VERSION || "dev";
export const APP_BASE_PATH = process.env.NEXT_PUBLIC_BASE_PATH || "";

export function appAsset(path: `/${string}`) {
    return `${APP_BASE_PATH}${path}`;
}

