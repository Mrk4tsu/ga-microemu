package org.microemu.ios;

import java.io.*;
import java.util.*;
import javax.microedition.rms.*;
import org.microemu.MicroEmulator;
import org.microemu.RecordStoreManager;
import org.microemu.util.ExtendedRecordListener;
import org.microemu.util.RecordStoreImpl;

/** Per-suite RMS snapshots. Writes survive close/reopen and preserve deleted record IDs. */
public final class IOSRecordStores implements RecordStoreManager {
    private static final int MAGIC = 0x4d455231;
    private final File directory;
    private final Map stores = new HashMap();
    private ExtendedRecordListener listener;
    private final class Store extends RecordStoreImpl {
        int highWater, references = 1;
        Store(String name) { super(IOSRecordStores.this, name); }
        public int getNextRecordID() throws RecordStoreNotOpenException, RecordStoreException {
            return Math.max(super.getNextRecordID(), highWater + 1);
        }
        public synchronized void closeRecordStore() throws RecordStoreNotOpenException, RecordStoreException {
            if (--references > 0) return;
            super.closeRecordStore();
        }
    }
    public IOSRecordStores(File directory) { this.directory = directory; }
    public void init(MicroEmulator emulator) {
        for (int attempt = 0; attempt < 3 && !directory.isDirectory(); attempt++) {
            directory.mkdirs();
        }
        if (!directory.isDirectory()) throw new IllegalStateException("Cannot create RMS directory");
    }
    public String getName() { return "iOS persistent RMS"; }
    /** Called only after all game threads have quiesced; writes are already persisted. */
    void closeAll() {
        for (Iterator i = stores.values().iterator(); i.hasNext();) ((Store)i.next()).setOpen(false);
        stores.clear();
    }
    private File file(String name) throws RecordStoreException {
        if (name == null || name.length() < 1 || name.length() > 32) throw new RecordStoreException("Invalid store name");
        StringBuffer encoded = new StringBuffer();
        for (int i = 0; i < name.length(); i++) { String part = Integer.toHexString(name.charAt(i)); for(int p=part.length();p<4;p++) encoded.append('0'); encoded.append(part); }
        return new File(directory, encoded.toString() + ".rms");
    }
    private void recover(File target) throws IOException {
        File backup = new File(target.getPath() + ".bak");
        if (!target.exists() && backup.exists() && !backup.renameTo(target)) throw new IOException("RMS recovery failed");
    }
    public synchronized RecordStore openRecordStore(String name, boolean create) throws RecordStoreException {
        Store cached = (Store)stores.get(name);
        if (cached != null && cached.isOpen()) { cached.references++; return cached; }
        Store store = new Store(name); File target = file(name);
        try {
            recover(target);
            if (target.exists()) {
                DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(target)));
                try {
                    if (in.readInt() != MAGIC) throw new IOException("Invalid RMS format");
                    store.highWater = in.readInt(); int count = store.readHeader(in);
                    if (count < 0 || count > 100000 || target.length() > 64L * 1024 * 1024) throw new IOException("Invalid RMS size");
                    for (int i = 0; i < count; i++) store.readRecord(in);
                } finally { in.close(); }
            } else if (!create) throw new RecordStoreNotFoundException(name);
            store.setOpen(true); stores.put(name, store);
            if (!target.exists()) save(store);
            return store;
        } catch (IOException error) { throw new RecordStoreException(error.toString()); }
    }
    private void save(Store store) throws RecordStoreException {
        synchronized (store) {
            try {
                File target = file(store.getName()), temporary = new File(target.getPath() + ".tmp"), backup = new File(target.getPath() + ".bak");
                DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(temporary)));
                try {
                    out.writeInt(MAGIC); out.writeInt(store.highWater); store.writeHeader(out);
                    RecordEnumeration records = store.enumerateRecords(null, null, false);
                    try { while (records.hasNextElement()) store.writeRecord(out, records.nextRecordId()); }
                    finally { records.destroy(); }
                } finally { out.close(); }
                if (!temporary.renameTo(target)) {
                    if (backup.exists() && !backup.delete()) throw new IOException("Cannot rotate RMS backup");
                    if (target.exists() && !target.renameTo(backup)) throw new IOException("Cannot preserve RMS snapshot");
                    if (!temporary.renameTo(target)) { backup.renameTo(target); throw new IOException("Cannot commit RMS snapshot"); }
                }
                if (backup.exists()) backup.delete();
            } catch (IOException error) { throw new RecordStoreException(error.toString()); }
        }
    }
    public void loadRecord(RecordStoreImpl store, int id) throws InvalidRecordIDException {
        if (id != -1) throw new InvalidRecordIDException("No record " + id);
    }
    public void saveRecord(RecordStoreImpl store, int id) throws RecordStoreException {
        Store persistent = (Store)store; persistent.highWater = Math.max(persistent.highWater, id); save(persistent);
    }
    public void deleteRecord(RecordStoreImpl store, int id) throws RecordStoreException { save((Store)store); }
    public synchronized void deleteRecordStore(String name) throws RecordStoreException {
        Store store = (Store)stores.get(name);
        if (store != null && store.isOpen()) throw new RecordStoreException("Record store is open");
        File target = file(name);
        try { recover(target); } catch (IOException e) { throw new RecordStoreException(e.toString()); }
        if (!target.exists()) throw new RecordStoreNotFoundException(name);
        if (!target.delete()) throw new RecordStoreException("Cannot delete RMS snapshot");
        new File(target.getPath() + ".bak").delete(); stores.remove(name);
    }
    public String[] listRecordStores() {
        String[] files = directory.list(); Vector names = new Vector();
        if (files != null) for (int i = 0; i < files.length; i++) {
            String name = files[i]; if (!name.endsWith(".rms")) continue;
            try { StringBuffer decoded = new StringBuffer(); for (int j = 0; j < name.length()-4; j += 4) decoded.append((char)Integer.parseInt(name.substring(j,j+4),16)); names.addElement(decoded.toString()); }
            catch (RuntimeException ignored) { }
        }
        if (names.isEmpty()) return null;
        String[] result = new String[names.size()]; names.copyInto(result); return result;
    }
    public void deleteStores() {
        String[] names = listRecordStores();
        if (names != null) for (int i = 0; i < names.length; i++) try { deleteRecordStore(names[i]); } catch (RecordStoreException e) { throw new IllegalStateException(e.toString()); }
    }
    public int getSizeAvailable(RecordStoreImpl store) { return 32 * 1024 * 1024; }
    public void setRecordListener(ExtendedRecordListener listener) { this.listener = listener; }
    public void fireRecordStoreListener(int type, String name) { }
}
