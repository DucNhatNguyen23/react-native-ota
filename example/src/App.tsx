import { useEffect, useState } from 'react';
import { Button, Platform, StyleSheet, Text, View } from 'react-native';
import {
  downloadBundle,
  getSavedVersion,
  removeBundle,
} from 'react-native-ota';
import { reloadApp } from 'react-native-reload-app';
type responseVersionCode = {
  versionCode: number;
};
export default function App() {
  const [stt] = useState<boolean>(false);
  const [err, setErr] = useState<string>('');

  const handleReset = async () => {
    try {
      const result = await reloadApp();
      console.log(result); // "Reload triggered"
    } catch (e) {
      console.error(e);
    }
  };

  const handleDownload = async () => {
    try {
      const response = await fetch('http://192.168.8.61:3000/ota/version');
      const getVersion: responseVersionCode = await response.json();
      console.log('versionCode', getVersion.versionCode);

      const savedVersion = getSavedVersion();
      console.log('savedVersion', savedVersion);

      if (savedVersion === getVersion.versionCode) {
        setErr('Khong co gi de update ca');
        return;
      }
      if (Platform.OS === 'ios') {
        const result = await downloadBundle(
          'http://192.168.8.61:3000/ota/ios-bundle',
          getVersion.versionCode
        );
        console.log('ios', result);
        setErr(result.message);
      }
      // console.log(result);

      // setStt(result);
    } catch (e) {
      console.error('loi dao', e);
      setErr(JSON.stringify(e));
    }
  };
  useEffect(() => {
    handleDownload();
  }, []);
  return (
    <View style={styles.container}>
      <Text>chua update dau nha {stt ? 'oke' : 'khong ok'}</Text>
      <Text>Errr: {err}</Text>
      <Button title="Press me" onPress={handleReset} />
      <Button title="Press me" onPress={removeBundle} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#fff',
  },
});
