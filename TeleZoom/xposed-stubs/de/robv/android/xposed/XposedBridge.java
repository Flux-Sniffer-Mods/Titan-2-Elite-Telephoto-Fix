package de.robv.android.xposed;
import java.util.Collections;
import java.util.Set;
public final class XposedBridge {
    public static void log(String text) {}
    public static void log(Throwable t) {}
    public static Set<Object> hookAllMethods(Class<?> hookClass, String methodName, XC_MethodHook callback) {
        return Collections.emptySet();
    }
}
