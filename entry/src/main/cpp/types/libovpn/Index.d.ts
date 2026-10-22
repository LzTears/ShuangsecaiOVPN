export const evaluate: (profile: string) => string;
export const start: (profile: string, username: string, password: string, keyPassword: string,
  listener: (message: string) => void) => boolean;
export const stop: () => void;
export const respond: (requestId: number, value: number) => boolean;
export const closeFd: (fd: number) => void;
export const snapshot: () => string;
