package org.microemu.ios;

import java.util.Vector;
import javax.microedition.lcdui.*;
import org.microemu.CustomItemAccess;
import org.microemu.DisplayAccess;
import org.microemu.device.ui.*;

/** Platform adapters; MicroEmulator's LCDUI models own raster layout and traversal. */
final class IOSUI implements UIFactory {
    static class Base implements DisplayableUI {
        final Displayable owner;
        final Vector commands = new Vector();
        private CommandListener listener;
        Base(Displayable owner) { this.owner = owner; }
        public void addCommandUI(CommandUI command) { if (!commands.contains(command)) commands.addElement(command); }
        public void removeCommandUI(CommandUI command) { commands.removeElement(command); }
        public CommandListener getCommandListener() { return listener; }
        public void setCommandListener(CommandListener listener) { this.listener = listener; }
        public void showNotify() { }
        public void hideNotify() { }
        public void invalidate() { }
        public Vector getCommandsUI() { return commands; }
        String[] labels() {
            String[] labels = new String[commands.size()];
            for (int i = 0; i < labels.length; i++) labels[i] = ((CommandUI)commands.elementAt(i)).getCommand().getLabel();
            return labels;
        }
    }
    static final class CanvasView extends Base implements CanvasUI {
        CanvasView(Canvas owner) { super(owner); }
        public void showNotify() { NativeBridge.modalTab(IOSRuntime.currentTabId(), null, null, 0, 0, new String[0]); }
    }
    /** The MIDP TextField model owns its value, constraints and raster rendering.
     * TextBox also creates one internally before opening the native text editor. */
    static class ItemView implements ItemUI {
        final Item item;
        ItemView(Item item) { this.item = item; }
        // Model setters have already updated their raster state.
        public void setDefaultCommand(Command command) { }
        public void setLabel(String label) { }
    }
    static final class FieldView extends ItemView implements TextFieldUI {
        private final TextField field;
        FieldView(TextField field) { super(field); this.field = field; }
        public void setConstraints(int constraints) { }
        public void setString(String text) { field.setString(text); }
        public String getString() { return field.getString(); }
    }
    static final class FormView extends Base implements FormUI {
        private final Form form;
        private ItemStateListener itemListener;
        FormView(Form form) { super(form); this.form = form; }
        public int append(ItemUI item) { return form.append(((ItemView)item).item); }
        public void delete(int index) { form.delete(index); }
        public void deleteAll() { form.deleteAll(); }
        public void insert(int index, ItemUI item) { form.insert(index, ((ItemView)item).item); }
        public void set(int index, ItemUI item) { form.set(index, ((ItemView)item).item); }
        public void setItemStateListener(ItemStateListener listener) { itemListener = listener; }
        public ItemStateListener getItemStateListener() { return itemListener; }
        public void showNotify() { NativeBridge.modalTab(IOSRuntime.currentTabId(), null, null, 0, 0, new String[0]); }
    }
    static final class ListView extends Base implements ListUI {
        private final List list;
        ListView(List list) { super(list); this.list = list; }
        public int append(String text, Image image) { return list.append(text, image); }
        public int getSelectedIndex() { return list.getSelectedIndex(); }
        public String getString(int index) { return list.getString(index); }
        public void setSelectCommand(Command command) { /* List owns the select command. */ }
        public void setSelectedIndex(int index, boolean selected) { list.setSelectedIndex(index, selected); }
        public void delete(int index) { list.delete(index); }
        public void deleteAll() { list.deleteAll(); }
        public void insert(int index, String text, Image image) { list.insert(index, text, image); }
        public void set(int index, String text, Image image) { list.set(index, text, image); }
        public int size() { return list.size(); }
        public void showNotify() { NativeBridge.modalTab(IOSRuntime.currentTabId(), null, null, 0, 0, new String[0]); }
    }
    static final class ChoiceView extends ItemView implements ChoiceGroupUI {
        private final ChoiceGroup group;
        ChoiceView(ChoiceGroup group) { super(group); this.group = group; }
        public void delete(int index) { group.delete(index); }
        public void deleteAll() { group.deleteAll(); }
        public void setSelectedIndex(int index, boolean selected) { group.setSelectedIndex(index, selected); }
        public int getSelectedIndex() { return group.getSelectedIndex(); }
        public void insert(int index, String text, Image image) { group.insert(index, text, image); }
        public boolean isSelected(int index) { return group.isSelected(index); }
        public void setSelectedFlags(boolean[] flags) { group.setSelectedFlags(flags); }
        public int getSelectedFlags(boolean[] flags) { return group.getSelectedFlags(flags); }
        public String getString(int index) { return group.getString(index); }
        public void set(int index, String text, Image image) { group.set(index, text, image); }
        public int size() { return group.size(); }
    }
    static final class GaugeView extends ItemView implements GaugeUI {
        private final Gauge gauge;
        GaugeView(Gauge gauge) { super(gauge); this.gauge = gauge; }
        public void setValue(int value) { gauge.setValue(value); }
        public int getValue() { return gauge.getValue(); }
        public void setMaxValue(int value) { gauge.setMaxValue(value); }
    }
    static final class ImageTextView extends ItemView implements ImageStringItemUI {
        ImageTextView(Item item) { super(item); }
        public void setImage(Image image) { /* ImageItem has already stored the bitmap and scheduled repaint. */ }
        public void setText(String text) {
            if (item instanceof StringItem) ((StringItem)item).setText(text);
            else if (item instanceof ImageItem) ((ImageItem)item).setAltText(text);
        }
    }
    static final class DateView extends ItemView implements DateFieldUI {
        private final DateField date;
        DateView(DateField date) { super(date); this.date = date; }
        public void setInputMode(int mode) { date.setInputMode(mode); }
        public void setDate(java.util.Date value) { date.setDate(value); }
        public java.util.Date getDate() { return date.getDate(); }
    }
    static final class CustomView extends ItemView implements CustomItemUI {
        CustomView(CustomItemAccess access) { super(access.getCustomItem()); }
        public void repaint() {
            org.microemu.MIDletAccess access = org.microemu.MIDletBridge.getMIDletAccess();
            if (access != null && access.getDisplayAccess() != null) access.getDisplayAccess().repaint();
        }
    }
    static final class TextView extends Base implements TextBoxUI {
        private String text = "";
        TextView(TextBox owner) { super(owner); }
        public int getCaretPosition() { return text.length(); }
        public String getString() { return text; }
        public void setString(String text) { this.text = text == null ? "" : text; }
        public void insert(String value, int position) { text = text.substring(0, position) + value + text.substring(position); }
        public void delete(int offset, int length) { text = text.substring(0, offset) + text.substring(offset + length); }
        public void showNotify() {
            TextBox box = (TextBox)owner;
            String title = box.getTitle();
            String current = box.getString();
            setString(current);
            NativeBridge.modalTab(IOSRuntime.currentTabId(), title == null ? "" : title, current == null ? "" : current, box.getMaxSize(), box.getConstraints(), labels());
        }
    }
    static final class AlertView extends Base implements AlertUI {
        private String text = "";
        AlertView(Alert owner) { super(owner); }
        public void setString(String text) { this.text = text; }
        public void showNotify() {
            String title = owner.getTitle();
            NativeBridge.modalTab(IOSRuntime.currentTabId(), title == null ? "" : title, text == null ? "" : text, 0, 0, labels());
        }
    }
    static boolean softKey(DisplayAccess display, int index) {
        Displayable owner = display.getCurrent();
        if (owner == null) return false;
        Base ui = (Base)display.getDisplayableUI(owner);
        if (ui.commands.isEmpty()) return false;
        int selected = index == 0 ? 0 : ui.commands.size() - 1;
        display.commandAction(((CommandUI)ui.commands.elementAt(selected)).getCommand(), owner); return true;
    }
    static void commit(DisplayAccess display, int index, String text) {
        Displayable owner = display.getCurrent();
        if (owner == null) return;
        Base ui = (Base)display.getDisplayableUI(owner);
        if (owner instanceof TextBox && text != null) {
            TextBox box = (TextBox)owner;
            int max = box.getMaxSize();
            String value = max > 0 && text.length() > max ? text.substring(0, max) : text;
            try {
                box.setString(value);
            } catch (IllegalArgumentException ignored) {
                // Keep Cancel/Back responsive even if input constraints fail.
            }
            if (ui instanceof TextView) ((TextView)ui).setString(value);
        } else if (ui instanceof TextView && text != null) {
            ((TextView)ui).setString(text);
        }
        if (index >= 0 && index < ui.commands.size())
            display.commandAction(((CommandUI)ui.commands.elementAt(index)).getCommand(), owner);
    }
    public EventDispatcher createEventDispatcher(Display display) {
        final org.microemu.MIDletContext context = org.microemu.MIDletBridge.getMIDletContext();
        EventDispatcher dispatcher = new EventDispatcher();
        final EventDispatcher target = dispatcher;
        Thread thread = new Thread(new Runnable() {
            public void run() {
                org.microemu.MIDletBridge.setThreadMIDletContext(context);
                target.run();
            }
        }, EventDispatcher.EVENT_DISPATCHER_NAME);
        thread.setDaemon(true); thread.start(); return dispatcher;
    }
    public CommandUI createCommandUI(final Command command) {
        return new CommandUI() {
            public Command getCommand() { return command; }
            public void setImage(Image image) { }
        };
    }
    public CanvasUI createCanvasUI(Canvas canvas) { return new CanvasView(canvas); }
    public TextBoxUI createTextBoxUI(TextBox box) { return new TextView(box); }
    public AlertUI createAlertUI(Alert alert) { return new AlertView(alert); }
    public FormUI createFormUI(Form form) { return new FormView(form); }
    public ListUI createListUI(List list) { return new ListView(list); }
    public ChoiceGroupUI createChoiceGroupUI(ChoiceGroup group, int type) { return new ChoiceView(group); }
    public CustomItemUI createCustomItemUI(CustomItemAccess item) { return new CustomView(item); }
    public DateFieldUI createDateFieldUI(DateField date) { return new DateView(date); }
    public GaugeUI createGaugeUI(Gauge gauge) { return new GaugeView(gauge); }
    public ImageStringItemUI createImageStringItemUI(Item item) { return new ImageTextView(item); }
    public TextFieldUI createTextFieldUI(TextField field) { return new FieldView(field); }
}
