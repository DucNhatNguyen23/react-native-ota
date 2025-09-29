import { TurboModuleRegistry, type TurboModule } from 'react-native';

export interface Spec extends TurboModule {
  downloadBundle(
    url: string,
    versionCode: number
  ): Promise<{ status: boolean; message: string }>;
  reloadApp(): Promise<string>;
  getSavedVersion(): number;
  removeBundle(): Promise<{ status: boolean; message: string }>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Ota');
