package legacy;

/** Java 11 emits legal invokevirtual calls to these same-class private methods. */
public class LegacyCalls {
    static final long WIDE_LONG = 0x123456789abcdefL;
    static final double WIDE_DOUBLE = 0.625;
    private int hidden(int n) { return n + 1; }
    private int hidden() { return 17; }
    private static int keepStatic() { return 7; }
    public int normal(int n) { return n * 2; }
    public int use() { return hidden(40) + hidden() + keepStatic() + normal(3); }
    public int table(int n) {
        switch (n) { case 0: return 4; case 1: return hidden(10); case 2: return 9; default: return 8; }
    }
    public int sparse(int n) {
        switch (n) { case -1000: return 4; case 1000: return hidden(); case 100000: return 9; default: return 8; }
    }
    public static int exercise() {
        LegacyCalls value = new Child();
        return value.use() + value.table(1) + value.sparse(1000);
    }
    static final class Child extends LegacyCalls {
        public int normal(int n) { return n + 8; }
        private int hidden(int n) { return -500; }
    }
}
