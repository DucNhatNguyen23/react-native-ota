import { Text, View, StyleSheet, Button } from 'react-native';
import { reloadApp } from 'react-native-ota';
import { useState } from 'react';
export default function App() {
  const [hello] = useState(0);
  const handleReset = async () => {
    try {
      const result = await reloadApp();
      console.log(result); // "Reload triggered"
    } catch (e) {
      console.error(e);
    }
  };
  return (
    <View style={styles.container}>
      <Text>Result: {hello}</Text>
      <Button title="Press me" onPress={handleReset} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
