package org.microemu.ios;

import java.util.Vector;
import javax.microedition.lcdui.*;
import org.microemu.CustomItemAccess;
import org.microemu.DisplayAccess;
import org.microemu.device.ui.*;

/** Canvas, commands, native text entry and alerts used by the initial MIDP profile. */
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
        public void showNotify() { NativeBridge.modal(null, null, 0, 0, new String[0]); }
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
            NativeBridge.modal(box.getTitle(), text, box.getMaxSize(), box.getConstraints(), labels());
        }
    }
    static final class AlertView extends Base implements AlertUI {
        private String text = "";
        AlertView(Alert owner) { super(owner); }
        public void setString(String text) { this.text = text; }
        public void showNotify() { NativeBridge.modal(owner.getTitle(), text, 0, 0, labels()); }
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
        if (ui instanceof TextView && text != null) ((TextView)ui).setString(text);
        if (index >= 0 && index < ui.commands.size())
            display.commandAction(((CommandUI)ui.commands.elementAt(index)).getCommand(), owner);
    }
    public EventDispatcher createEventDispatcher(Display display) {
        EventDispatcher dispatcher = new EventDispatcher();
        Thread thread = new Thread(dispatcher, EventDispatcher.EVENT_DISPATCHER_NAME);
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
    private <T> T unsupported(String name) { throw new UnsupportedOperationException("MIDP UI not yet supported: " + name); }
    public FormUI createFormUI(Form form) { return unsupported("Form"); }
    public ListUI createListUI(List list) { return unsupported("List"); }
    public ChoiceGroupUI createChoiceGroupUI(ChoiceGroup group, int type) { return unsupported("ChoiceGroup"); }
    public CustomItemUI createCustomItemUI(CustomItemAccess item) { return unsupported("CustomItem"); }
    public DateFieldUI createDateFieldUI(DateField date) { return unsupported("DateField"); }
    public GaugeUI createGaugeUI(Gauge gauge) { return unsupported("Gauge"); }
    public ImageStringItemUI createImageStringItemUI(Item item) { return unsupported("Item"); }
    public TextFieldUI createTextFieldUI(TextField field) { return unsupported("TextField"); }
}
