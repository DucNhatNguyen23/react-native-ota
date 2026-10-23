import {
  TurboModuleRegistry,
  type CodegenTypes,
  type TurboModule,
} from 'react-native';

export type DownloadProgress = {
  // 'download' | 'unzip'
  phase: string;
  // 0-100, or -1 when the server does not send Content-Length
  progress: number;
  // download: bytes, unzip: entries
  received: number;
  total: number;
};

export interface Spec extends TurboModule {
  downloadBundle(
    url: string,
    versionCode: number,
    sha256: string | null
  ): Promise<{ status: boolean; message: string }>;
  reloadApp(): Promise<string>;
  getSavedVersion(): number;
  getFailedVersion(): number;
  getNativeVersion(): string;
  notifyAppReady(): void;
  removeBundle(): Promise<{ status: boolean; message: string }>;

  readonly onProgress: CodegenTypes.EventEmitter<DownloadProgress>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Ota');
