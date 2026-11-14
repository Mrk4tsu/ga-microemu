package session;

import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.*;

public final class UIAdaptersMIDlet extends MIDlet implements CommandListener, ItemStateListener {
    private Form form;
    private TextField field;
    private List list;
    private Command next = new Command("Next", Command.OK, 0);
    public void startApp() {
        form = new Form("Adapter form");
        field = new TextField("Name", "", 24, TextField.ANY);
        form.append(field);
        form.append(new StringItem("Label", "Raster layout"));
        form.append(new ImageItem("Image", Image.createImage(16, 16), Item.LAYOUT_DEFAULT, "icon"));
        ChoiceGroup group = new ChoiceGroup("Choice", Choice.MULTIPLE, new String[]{"A", "B"}, null);
        group.setSelectedIndex(1, true);
        if (!group.isSelected(1) || group.getSelectedIndex() != -1) throw new Error("Choice flags");
        form.append(group);
        Gauge gauge = new Gauge("Gauge", true, 10, 3);
        gauge.setValue(7);
        if (gauge.getValue() != 7) throw new Error("Gauge model");
        form.append(gauge);
        DateField date = new DateField("Date", DateField.DATE_TIME);
        date.setDate(new java.util.Date(1234567890000L));
        if (date.getDate() == null) throw new Error("Date model");
        form.append(date);
        form.append(new CustomItem("Custom") {
            private boolean painted;
            protected int getMinContentWidth() { return 16; }
            protected int getMinContentHeight() { return 16; }
            protected int getPrefContentWidth(int height) { return 16; }
            protected int getPrefContentHeight(int width) { return 16; }
            protected void paint(Graphics g, int w, int h) {
                g.setColor(0xff5500); g.fillRect(0, 0, w, h);
                if (!painted) { painted = true; System.out.println("UI_CUSTOM_PAINT"); }
            }
        });
        form.addCommand(next); form.setCommandListener(this); form.setItemStateListener(this);
        Display.getDisplay(this).setCurrent(form);
        System.out.println("UI_FORM_READY");
        org.microemu.ios.NativeBridge.status("UI_ARM_SCHEDULE");
    }
    public void itemStateChanged(Item item) {
        if (item == field && "adapter text".equals(field.getString())) System.out.println("UI_FIELD_PASS");
    }
    public void commandAction(Command command, Displayable owner) {
        if (owner == form) {
            if (!"adapter text".equals(field.getString())) throw new Error("Field input not committed");
            list = new List("Adapter list", Choice.IMPLICIT, new String[]{"First", "Second", "Third"}, null);
            list.setCommandListener(this); list.setSelectCommand(next);
            Display.getDisplay(this).setCurrent(list);
            System.out.println("UI_LIST_READY");
        } else if (owner == list) {
            if (command != next || list.getSelectedIndex() != 1) throw new Error("List focus/command");
            System.out.println("UI_ADAPTERS_PASS");
            notifyDestroyed();
        }
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
