package io.jsbay.consumer;

public final class ConsumerMain {
  public static void main(String[] args) {
    if (Boolean.getBoolean("jsbay.android.bridgeFault")) {
      JavaConsumer.runBridgeFaultRecovery();
      System.out.println("PASS: Android JNI bridge fault consumer");
      return;
    }
    JavaConsumer.run();
    KotlinConsumerKt.runKotlinConsumer();
    System.out.println("PASS: Android Java and Kotlin consumers");
  }
}
