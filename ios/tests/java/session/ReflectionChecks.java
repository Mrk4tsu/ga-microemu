package session;

public final class ReflectionChecks {
    public static class Target {
        public static int value = 7;
        public Target() { }
        public int ping() { return 42; }
        private void hidden() { }
    }
    public static void main(String[] args) throws Exception {
        Class c = Target.class;
        Object target = c.getConstructor((Class[])null).newInstance((Object[])null);
        if (((Integer)c.getMethod("ping", (Class[])null).invoke(target, (Object[])null)).intValue() != 42)
            throw new Error("invoke result");
        c.getDeclaredMethod("ping", (Class[])null);
        c.getDeclaredConstructor((Class[])null);
        if (((Integer)c.getField("value").get(null)).intValue() != 7) throw new Error("field");
        try { c.getMethod("hidden", (Class[])null); throw new Error("private lookup accepted"); }
        catch (NoSuchMethodException expected) { }
        try { c.getMethod("ping", new Class[]{String.class}); throw new Error("wrong signature accepted"); }
        catch (NoSuchMethodException expected) { }
        System.out.println("SESSION_REFLECTION_PASS");
    }
}
