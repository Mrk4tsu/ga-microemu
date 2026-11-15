package com.gamod.gaemulator;

import android.app.*;
import android.content.*;
import android.text.InputType;
import android.view.*;
import android.widget.*;
import java.util.function.Consumer;

/** Per-JAR launch choices; a full screen choice resolves against the current game area. */
final class GameSettings {
    static final int MIN=128,MAX=1920;
    static final class Choice {
        final int width,height; final boolean full;
        Choice(int width,int height,boolean full) { this.width=width;this.height=height;this.full=full; }
    }
    private final SharedPreferences preferences;
    GameSettings(Context context) { preferences=context.getSharedPreferences("game-screens",Context.MODE_PRIVATE); }
    static boolean valid(int width,int height) { return width>=MIN && width<=MAX && height>=MIN && height<=MAX; }
    Choice load(GameStore.Game game) {
        String key=game.hash;
        if(!preferences.contains(key+".width"))return null;
        try {
            int width=preferences.getInt(key+".width",0),height=preferences.getInt(key+".height",0);
            return valid(width,height)?new Choice(width,height,preferences.getBoolean(key+".full",false)):null;
        } catch(ClassCastException error) { return null; }
    }
    void save(GameStore.Game game,Choice choice) {
        if(!valid(choice.width,choice.height))throw new IllegalArgumentException("Screen dimensions must be 128..1920");
        preferences.edit().putInt(game.hash+".width",choice.width).putInt(game.hash+".height",choice.height).putBoolean(game.hash+".full",choice.full).apply();
    }
    AlertDialog dialog(Activity activity,GameStore.Game game,boolean editing,Consumer<Choice> accepted) {
        int[][] presets={{240,320},{320,240},{320,480},{480,320},{480,800},{800,480}};
        Choice old=load(game); Choice initial=old==null?new Choice(240,320,false):old;
        LinearLayout box=new LinearLayout(activity); box.setOrientation(LinearLayout.VERTICAL);box.setPadding(24,12,24,12);
        Spinner sizes=new Spinner(activity);
        sizes.setAdapter(new ArrayAdapter<>(activity,android.R.layout.simple_spinner_dropdown_item,new String[]{"Full màn hình (tự động)","240 × 320","320 × 240","320 × 480","480 × 320","480 × 800","800 × 480","Tùy chỉnh"}));
        box.addView(sizes);
        EditText width=dimension(activity,"Chiều rộng (px)",initial.width),height=dimension(activity,"Chiều cao (px)",initial.height);
        box.addView(width);box.addView(height);
        TextView help=new TextView(activity);
        help.setText("Mỗi chiều 128–1920 px. Full màn hình tự phóng đầy vùng chơi và thử ảnh nhỏ hơn nếu lỗi lúc mở.\n"+(editing?"Lưu để áp dụng ở lần mở tiếp theo.":"Chỉ thiết lập lần đầu. Dùng ⓘ trong thư viện để đổi về sau."));box.addView(help);
        int selected=initial.full?0:7;
        if(!initial.full)for(int i=0;i<presets.length;i++)if(initial.width==presets[i][0] && initial.height==presets[i][1])selected=i+1;
        sizes.setSelection(selected);
        sizes.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            public void onNothingSelected(AdapterView<?> parent) { }
            public void onItemSelected(AdapterView<?> parent,View view,int position,long id) {
                width.setEnabled(position!=0);height.setEnabled(position!=0);
                if(position>0 && position<=presets.length) { width.setText(Integer.toString(presets[position-1][0]));height.setText(Integer.toString(presets[position-1][1])); }
            }
        });
        ScrollView scroll=new ScrollView(activity);scroll.addView(box);
        AlertDialog dialog=new AlertDialog.Builder(activity).setTitle(editing?"Kích thước màn hình":"Thiết lập lần đầu").setMessage(game.name).setView(scroll)
            .setPositiveButton(editing?"Lưu":"Chạy",null).setNegativeButton("Hủy",null).create();
        dialog.setOnShowListener(value->dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(button->{
            boolean full=sizes.getSelectedItemPosition()==0;int w=240,h=320;
            try { if(!full) { w=Integer.parseInt(width.getText().toString().trim());h=Integer.parseInt(height.getText().toString().trim()); } }
            catch(NumberFormatException error) { width.setError("Nhập số từ 128 tới 1920");return; }
            if(!valid(w,h)) { width.setError("Mỗi chiều phải từ 128 tới 1920 px");height.setError("Mỗi chiều phải từ 128 tới 1920 px");return; }
            Choice choice=new Choice(w,h,full);save(game,choice);dialog.dismiss();accepted.accept(choice);
        }));
        return dialog;
    }
    private EditText dimension(Activity activity,String label,int value) {
        EditText field=new EditText(activity);field.setHint(label);field.setContentDescription(label);field.setSingleLine(true);
        field.setInputType(InputType.TYPE_CLASS_NUMBER);field.setText(Integer.toString(value));return field;
    }
}
