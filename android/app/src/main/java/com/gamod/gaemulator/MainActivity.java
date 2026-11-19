package com.gamod.gaemulator;

import android.app.*;
import android.content.*;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.*;
import android.text.*;
import android.text.method.PasswordTransformationMethod;
import android.view.*;
import android.view.inputmethod.*;
import android.widget.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

public final class MainActivity extends Activity implements NativeEngine.Listener {
    private static final int PICK_JAR=10;
    private final Handler ui=new Handler(Looper.getMainLooper());
    private final ExecutorService files=Executors.newSingleThreadExecutor();
    private final LinkedHashMap<Integer,Tab> tabs=new LinkedHashMap<>();
    private final HashMap<Button,Integer> held=new HashMap<>();
    private LinearLayout root,player,playArea,controls,pad,keyboard;
    private ListView library;
    private TextView status;
    private Button stop,tabsButton;
    private GameView screen;
    private GameEditText typing;
    private GameStore store;
    private GameSettings settings;
    private AlertDialog settingsDialog;
    private final ArrayDeque<GameStore.Game> pendingGames=new ArrayDeque<>();
    private RuntimeAssets assets;
    private int active,nextId=1;
    private boolean ready,resumed,skipText;
    private String previous="";
    private AlertDialog textDialog;
    private final ArrayDeque<Uri> pendingImports=new ArrayDeque<>();
    private static final class Tab {
        int id; GameStore.Game game; Bitmap frame; boolean stopping,opened;
        GameSettings.Choice screenSize; int requestedWidth,requestedHeight;
        String status="",title,value; int max,constraints; String[] commands;
    }
    private int dp(int value) { return Math.round(value*getResources().getDisplayMetrics().density); }
    private LinearLayout row() { LinearLayout view=new LinearLayout(this); view.setGravity(Gravity.CENTER_VERTICAL); return view; }
    private Button button(String label,Runnable action) {
        Button button=new Button(this); button.setText(label); button.setAllCaps(false); button.setTextSize(13); button.setMinWidth(0); button.setMinimumWidth(0);
        if(action!=null) button.setOnClickListener(v->action.run()); return button;
    }
    private void addButton(LinearLayout row,Button button) { row.addView(button,new LinearLayout.LayoutParams(0,dp(44),1)); }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        root=new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setBackgroundColor(Color.rgb(11,13,16));
        if(Build.VERSION.SDK_INT>=30) {
            getWindow().setDecorFitsSystemWindows(false);
            root.setOnApplyWindowInsetsListener((view,insets)->{
                android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout()|WindowInsets.Type.ime());
                view.setPadding(bars.left,bars.top,bars.right,bars.bottom); return insets;
            });
        } else root.setFitsSystemWindows(true);
        LinearLayout toolbar=row();
        stop=button("Dừng",this::stopActive); addButton(toolbar,stop);
        addButton(toolbar,button("Mở JAR",this::pickJar));
        tabsButton=button("Tab",this::chooseTab); addButton(toolbar,tabsButton);
        addButton(toolbar,button("Bàn phím",this::showKeyboard)); addButton(toolbar,button("Log",this::showLog)); root.addView(toolbar);
        status=new TextView(this); status.setTextColor(Color.LTGRAY); status.setPadding(dp(10),dp(3),dp(10),dp(3)); status.setText(R.string.preparing); root.addView(status);
        FrameLayout content=new FrameLayout(this); root.addView(content,new LinearLayout.LayoutParams(-1,0,1));
        library=new ListView(this); content.addView(library,new FrameLayout.LayoutParams(-1,-1));
        player=new LinearLayout(this); player.setOrientation(LinearLayout.VERTICAL); content.addView(player,new FrameLayout.LayoutParams(-1,-1));
        playArea=new LinearLayout(this); player.addView(playArea,new LinearLayout.LayoutParams(-1,0,1));
        screen=new GameView(this); playArea.addView(screen,new LinearLayout.LayoutParams(-1,0,1));
        keyboard=row(); keyboard.setVisibility(View.GONE);
        typing=new GameEditText(); typing.setSingleLine(true); typing.setHint("Gõ nội dung gửi vào game");
        typing.setTextSize(15); typing.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        typing.setTransformationMethod(PasswordTransformationMethod.getInstance());
        typing.setImeOptions(EditorInfo.IME_ACTION_GO); keyboard.addView(typing,new LinearLayout.LayoutParams(0,dp(48),1));
        keyboard.addView(button("↵",()->{ commitTyping(); tap(-5); clearTyping(); })); keyboard.addView(button("Xong",this::hideKeyboard));
        player.addView(keyboard);
        typing.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s,int start,int count,int after) { }
            public void onTextChanged(CharSequence s,int start,int before,int count) { }
            public void afterTextChanged(Editable text) { if(!skipText && BaseInputConnection.getComposingSpanStart(text)==-1) sendTyping(); }
        });
        typing.setOnEditorActionListener((v,action,event)->{ commitTyping(); tap(-5); clearTyping(); return true; });
        controls=new LinearLayout(this); controls.setOrientation(LinearLayout.VERTICAL); controls.setGravity(Gravity.CENTER_VERTICAL);
        pad=new LinearLayout(this); pad.setOrientation(LinearLayout.VERTICAL);
        LinearLayout padToggle=row(); addButton(padToggle,button("Ẩn / hiện phím",()->pad.setVisibility(pad.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE))); controls.addView(padToggle); controls.addView(pad); playArea.addView(controls);
        LinearLayout columns=row();
        int[][][] codes={{{-6,-1,-7},{-3,-5,-4},{0,-2,0}},{{'1','2','3'},{'4','5','6'},{'7','8','9'},{'*','0','#'}}};
        String[][][] labels={{{"L","↑","R"},{"←","OK","→"},{"","↓",""}},{{"1","2","3"},{"4","5","6"},{"7","8","9"},{"*","0","#"}}};
        for(int group=0;group<codes.length;group++) {
            LinearLayout column=new LinearLayout(this); column.setOrientation(LinearLayout.VERTICAL);
            for(int r=0;r<codes[group].length;r++) {
                LinearLayout keys=row();
                for(int c=0;c<codes[group][r].length;c++) {
                    Button key=button(labels[group][r][c],null);
                    key.setPadding(dp(2),0,dp(2),0);
                    if(codes[group][r][c]!=0) wireKey(key,codes[group][r][c]); else key.setEnabled(false);
                    addButton(keys,key);
                }
                column.addView(keys);
            }
            columns.addView(column,new LinearLayout.LayoutParams(0,-2,1));
        }
        pad.addView(columns); configureControls();
        player.setVisibility(View.GONE); setContentView(root); NativeEngine.listen(this);
        files.execute(()->{
            try { store=new GameStore(this);settings=new GameSettings(this); assets=RuntimeAssets.install(this);
                if(isFinishing() || isDestroyed()) return;
                ActivityManager.MemoryInfo memory=new ActivityManager.MemoryInfo(); ((ActivityManager)getSystemService(ACTIVITY_SERVICE)).getMemoryInfo(memory);
                NativeEngine.startHost(assets,memory.totalMem);
                ui.post(()->{ if(isFinishing() || isDestroyed())return;ready=true; refreshLibrary();while(!pendingImports.isEmpty())importGame(pendingImports.removeFirst()); });
            } catch(Exception error) { ui.post(()->message("Không khởi động được",error.toString())); }
        });
        handleIntent(getIntent()); ui.post(poll);
    }
    private void configureControls() {
        boolean landscape=getResources().getConfiguration().orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE;
        playArea.setOrientation(landscape?LinearLayout.HORIZONTAL:LinearLayout.VERTICAL);
        screen.setLayoutParams(landscape?new LinearLayout.LayoutParams(0,-1,1):new LinearLayout.LayoutParams(-1,0,1));
        controls.setLayoutParams(landscape?new LinearLayout.LayoutParams(dp(250),-1):new LinearLayout.LayoutParams(-1,-2));
    }
    @Override public void onConfigurationChanged(android.content.res.Configuration configuration) { releaseKeys();super.onConfigurationChanged(configuration); configureControls(); }
    @android.annotation.SuppressLint("ClickableViewAccessibility") // Releases call performClick; accessibility clicks send a tap.
    private void wireKey(Button key,int code) {
        key.setOnClickListener(v->{ if(!held.containsKey(key)) tap(code); });
        key.setOnTouchListener((v,event)->{
            if(active==0) return false;
            if(event.getActionMasked()==MotionEvent.ACTION_DOWN) {
                if(!held.containsKey(key)) { int tab=active; held.put(key,code); NativeEngine.event(tab,1,code,0,null);
                    ui.postDelayed(new Runnable() { public void run() { if(held.containsKey(key) && active==tab) { NativeEngine.event(tab,3,code,0,null); ui.postDelayed(this,70); } } },350);
                }
                return true;
            }
            if(event.getActionMasked()==MotionEvent.ACTION_UP || event.getActionMasked()==MotionEvent.ACTION_CANCEL) {
                Integer pressed=held.get(key); if(pressed!=null) NativeEngine.event(active,2,pressed,0,null); v.performClick(); held.remove(key); return true;
            }
            return true;
        });
    }
    private void releaseKeys() { for(Integer code:held.values()) if(active!=0) NativeEngine.event(active,2,code,0,null); held.clear(); if(screen!=null) screen.release(); }
    private void tap(int code) { if(active!=0) NativeEngine.event(active,13,code,0,null); }
    private void pickJar() {
        Intent pick=new Intent(Intent.ACTION_OPEN_DOCUMENT); pick.addCategory(Intent.CATEGORY_OPENABLE); pick.setType("*/*");
        startActivityForResult(pick,PICK_JAR);
    }
    @Override protected void onActivityResult(int request,int result,Intent data) {
        super.onActivityResult(request,result,data); if(request==PICK_JAR && result==RESULT_OK && data!=null && data.getData()!=null) importGame(data.getData());
    }
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); handleIntent(intent); }
    private void handleIntent(Intent intent) {
        if(intent==null) return;
        Uri uri=Intent.ACTION_SEND.equals(intent.getAction())?intent.getParcelableExtra(Intent.EXTRA_STREAM):intent.getData();
        if(uri!=null && ("content".equals(uri.getScheme()) || "file".equals(uri.getScheme()))) importGame(uri);
    }
    private void importGame(Uri uri) {
        if(!ready) { pendingImports.addLast(uri); return; }
        status.setText(R.string.importing);
        files.execute(()->{ try { GameStore.Game game=store.importJar(uri); ui.post(()->{ refreshLibrary(); open(game); }); }
            catch(Exception error) { ui.post(()->message("Không mở được JAR",error.getMessage())); } });
    }
    private void refreshLibrary() {
        files.execute(()->{ try { List<GameStore.Game> games=store.list(); ui.post(()->{
            library.setAdapter(new ArrayAdapter<GameStore.Game>(this,android.R.layout.simple_list_item_1,games) {
                @Override public View getView(int position,View reusable,ViewGroup parent) {
                    GameStore.Game game=getItem(position);LinearLayout item=row();item.setPadding(dp(12),dp(4),dp(8),dp(4));
                    LinearLayout labels=new LinearLayout(MainActivity.this);labels.setOrientation(LinearLayout.VERTICAL);
                    TextView name=new TextView(MainActivity.this);name.setText(game.name);name.setTextColor(Color.WHITE);name.setTextSize(17);labels.addView(name);
                    TextView author=new TextView(MainActivity.this);author.setText(game.author.isEmpty()?"Java ME":game.author);author.setTextColor(Color.LTGRAY);labels.addView(author);
                    item.addView(labels,new LinearLayout.LayoutParams(0,-2,1));
                    Button edit=button("ⓘ",()->editSettings(game));edit.setContentDescription("Đổi kích thước: "+game.name);edit.setFocusable(false);item.addView(edit,new LinearLayout.LayoutParams(dp(56),dp(48)));return item;
                }
            });
            library.setOnItemClickListener((p,v,position,id)->open(games.get(position)));
            if(active==0) status.setText(games.isEmpty()?"Chọn Mở JAR để thêm game Java ME":"Chọn game để chạy"); updateToolbar();
        }); } catch(Exception error) { ui.post(()->message("Lỗi thư viện",error.getMessage())); } });
    }
    private void open(GameStore.Game game) {
        if(!ready || !NativeEngine.isRunning()) { message("Runtime chưa sẵn sàng","Hãy đóng và mở lại ứng dụng."); return; }
        pendingGames.addLast(game);processOpenQueue();
    }
    private void processOpenQueue() {
        if(settingsDialog!=null || pendingGames.isEmpty() || isFinishing() || isDestroyed())return;
        GameStore.Game game=pendingGames.removeFirst();
        for(Tab tab:tabs.values()) if(tab.game.hash.equals(game.hash)) { select(tab.id);ui.post(this::processOpenQueue);return; }
        if(tabs.size()>=8) { pendingGames.clear();message("Đã mở 8 tab","Dừng một game trước khi mở thêm."); return; }
        GameSettings.Choice saved=settings.load(game);
        if(saved==null)showSettings(game,false);
        else { launch(game,saved);ui.post(this::processOpenQueue); }
    }
    private void editSettings(GameStore.Game game) { if(settingsDialog==null)showSettings(game,true); }
    private void showSettings(GameStore.Game game,boolean editing) {
        releaseKeys();hideKeyboard();dismissEditor();
        settingsDialog=settings.dialog(this,game,editing,choice->{if(!editing)launch(game,choice);});
        settingsDialog.setOnDismissListener(dialog->{
            settingsDialog=null;
            ui.post(()->{ processOpenQueue();Tab tab=tabs.get(active);if(settingsDialog==null && tab!=null && tab.title!=null && textDialog==null)showEditor(tab); });
        });
        settingsDialog.show();
    }
    private void launch(GameStore.Game game,GameSettings.Choice choice) {
        if(!ready || !NativeEngine.isRunning() || isFinishing() || isDestroyed())return;
        Tab tab=new Tab(); tab.id=nextId++; tab.game=game;tab.screenSize=choice; tab.status="Đang mở "+game.name; tabs.put(tab.id,tab); select(tab.id);
        screen.post(new Runnable() { public void run() {
            if(!tabs.containsKey(tab.id) || tab.stopping || isFinishing() || isDestroyed())return;
            // GONE -> VISIBLE requests a later layout; View.post alone does not
            // guarantee the full game area has been measured yet.
            if(choice.full && (screen.getWidth()==0 || screen.getHeight()==0 || screen.isLayoutRequested())) { screen.postDelayed(this,16);return; }
            try {
                float density=getResources().getDisplayMetrics().density;
                int width=choice.full?Math.max(GameSettings.MIN,Math.min(GameSettings.MAX,Math.round(screen.getWidth()/density))):choice.width;
                int height=choice.full?Math.max(GameSettings.MIN,Math.min(GameSettings.MAX,Math.round(screen.getHeight()/density))):choice.height;
                tab.requestedWidth=width;tab.requestedHeight=height;
                tab.opened=true;
                NativeEngine.openTab(tab.id,game.file.getPath(),store.rms(game).getPath(),width,height,choice.full);
                NativeEngine.sleepTab(tab.id,active!=tab.id);
                if(!resumed)NativeEngine.event(tab.id,8,0,0,null);
            } catch(Exception error) { finished(tab.id,-1); message("Không mở được",error.getMessage()); }
        }});
    }
    private void select(int id) {
        releaseKeys(); hideKeyboard(); dismissEditor();
        Tab old=tabs.get(active); if(old!=null) { old.frame=screen.frame(); NativeEngine.sleepTab(old.id,true); }
        active=id; Tab tab=tabs.get(id); player.setVisibility(tab==null?View.GONE:View.VISIBLE); library.setVisibility(tab==null?View.VISIBLE:View.GONE);
        screen.select(id,tab==null?null:tab.frame);
        screen.fullScreen(tab!=null && tab.screenSize!=null && tab.screenSize.full);
        if(tab!=null) { NativeEngine.sleepTab(tab.id,false); status.setText(tab.status); if(tab.title!=null) showEditor(tab); }
        updateToolbar();
    }
    private void chooseTab() {
        if(tabs.isEmpty()) { player.setVisibility(View.GONE); library.setVisibility(View.VISIBLE); return; }
        List<Tab> list=new ArrayList<>(tabs.values()); String[] names=new String[list.size()+1];
        for(int i=0;i<list.size();i++) names[i]=list.get(i).game.name+(list.get(i).stopping?" · đang dừng":"");
        names[list.size()]="Thư viện game";
        new AlertDialog.Builder(this).setTitle("Chọn tab").setItems(names,(d,index)->{ if(index==list.size()) select(0); else select(list.get(index).id); }).show();
    }
    private void stopActive() {
        Tab tab=tabs.get(active); if(tab==null || tab.stopping) return;
        if(!tab.opened) { finished(tab.id,0);return; }
        releaseKeys(); hideKeyboard(); dismissEditor(); tab.stopping=true; status.setText(R.string.stopping); NativeEngine.closeTab(tab.id); updateToolbar();
    }
    private void updateToolbar() { Tab tab=tabs.get(active); stop.setEnabled(tab!=null && !tab.stopping); tabsButton.setText(getString(R.string.tab_count,tabs.size())); }
    private void showKeyboard() { if(active==0) return; keyboard.setVisibility(View.VISIBLE); controls.setVisibility(View.GONE); typing.requestFocus(); ((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).showSoftInput(typing,InputMethodManager.SHOW_IMPLICIT); }
    private void clearTyping() { skipText=true; typing.setText(""); previous=""; skipText=false; }
    private void hideKeyboard() {
        if(typing==null) return; commitTyping(); ((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(typing.getWindowToken(),0);
        typing.clearFocus(); clearTyping(); keyboard.setVisibility(View.GONE); if(controls!=null) controls.setVisibility(View.VISIBLE);
    }
    private void commitTyping() { if(typing!=null) { BaseInputConnection.removeComposingSpans(typing.getText()); sendTyping(); } }
    private void sendTyping() {
        if(skipText || active==0) return; String current=typing.getText().toString(); int common=0,limit=Math.min(current.length(),previous.length());
        while(common<limit && current.charAt(common)==previous.charAt(common)) common++;
        for(int i=common;i<previous.length();i++) tap(-8);
        if(common<current.length()) NativeEngine.event(active,12,0,0,current.substring(common)); previous=current;
    }
    private final class GameEditText extends EditText {
        GameEditText() { super(MainActivity.this); }
        @Override public InputConnection onCreateInputConnection(EditorInfo info) {
            InputConnection original=super.onCreateInputConnection(info);
            return new InputConnectionWrapper(original,false) {
                private boolean emptyDelete() { if(getText().length()==0) { tap(-8); return true; } return false; }
                @Override public boolean deleteSurroundingText(int before,int after) { return before>0 && emptyDelete() || super.deleteSurroundingText(before,after); }
                @Override public boolean deleteSurroundingTextInCodePoints(int before,int after) { return before>0 && emptyDelete() || super.deleteSurroundingTextInCodePoints(before,after); }
                @Override public boolean sendKeyEvent(KeyEvent event) {
                    if(event.getKeyCode()==KeyEvent.KEYCODE_DEL && getText().length()==0) { if(event.getAction()==KeyEvent.ACTION_DOWN) tap(-8); return true; }
                    return super.sendKeyEvent(event);
                }
            };
        }
    }
    private final Runnable poll=new Runnable() { public void run() {
        if(resumed && active!=0) { int[] frame=NativeEngine.takeFrame(active); if(frame!=null) { screen.frame(frame); Tab tab=tabs.get(active); if(tab!=null) tab.frame=screen.frame(); } }
        ui.postDelayed(this,16);
    }};
    @Override public void status(int id,String value) {
        Tab tab=tabs.get(id); if(tab!=null) tab.status=value;
        if(id==active || id==0) status.setText(value);
    }
    @Override public void finished(int id,int result) {
        Tab tab=tabs.remove(id); if(tab==null) return;
        if(active==id) select(tabs.isEmpty()?0:tabs.keySet().iterator().next()); updateToolbar();
        if(result!=0) message("Game đã dừng do lỗi","Kích thước "+tab.requestedWidth+" × "+tab.requestedHeight+". Mở Log để xem lỗi ảnh/khởi động. Dùng ⓘ trong thư viện để chọn kích thước nhỏ hơn hoặc Full màn hình.");
        if(tabs.isEmpty()) refreshLibrary();
    }
    @Override public void modal(int id,String title,String value,int max,int constraints,String[] commands) {
        Tab tab=tabs.get(id); if(tab==null || tab.stopping) return;
        tab.title=title; tab.value=value; tab.max=max; tab.constraints=constraints; tab.commands=commands;
        if(id!=active) return; if(title==null) dismissEditor(); else showEditor(tab);
    }
    private void dismissEditor() { if(textDialog!=null) { textDialog.setOnCancelListener(null); textDialog.dismiss(); textDialog=null; } }
    private void showEditor(Tab tab) {
        if(settingsDialog!=null)return;
        dismissEditor(); hideKeyboard();
        LinearLayout box=new LinearLayout(this); box.setOrientation(LinearLayout.VERTICAL); box.setPadding(dp(20),dp(4),dp(20),dp(4));
        EditText field=null;
        if(tab.max>0) {
            field=new EditText(this); field.setSingleLine(false); int type=tab.constraints&0xffff;
            int input=type==2?InputType.TYPE_CLASS_NUMBER|InputType.TYPE_NUMBER_FLAG_SIGNED:type==3?InputType.TYPE_CLASS_PHONE:type==5?InputType.TYPE_CLASS_NUMBER|InputType.TYPE_NUMBER_FLAG_DECIMAL|InputType.TYPE_NUMBER_FLAG_SIGNED:InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            if(type==1) input|=InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS; if(type==4) input|=InputType.TYPE_TEXT_VARIATION_URI;
            field.setInputType(input); if((tab.constraints&0x10000)!=0) field.setTransformationMethod(PasswordTransformationMethod.getInstance());
            field.setFilters(new InputFilter[]{new InputFilter.LengthFilter(tab.max)}); field.setText(tab.value==null?"":tab.value); field.setSelection(field.length());
            field.setEnabled((tab.constraints&0x20000)==0); box.addView(field);
        } else { TextView text=new TextView(this); text.setText(tab.value); box.addView(text); }
        final EditText editor=field; String[] labels=tab.commands==null || tab.commands.length==0?new String[]{"Xong"}:tab.commands;
        AlertDialog.Builder builder=new AlertDialog.Builder(this).setTitle(tab.title).setView(box);
        for(int i=0;i<labels.length;i++) {
            final int index=i; DialogInterface.OnClickListener accept=(dialog,which)->commitEditor(tab,editor,index);
            if(i==0) builder.setPositiveButton(labels[i],accept);
            else if(i==1) builder.setNegativeButton(labels[i],accept);
            else if(i==2) builder.setNeutralButton(labels[i],accept);
            else box.addView(button(labels[i],()->{ commitEditor(tab,editor,index); dismissEditor(); }));
        }
        textDialog=builder.create();
        textDialog.setOnCancelListener(dialog->commitEditor(tab,editor,labels.length>1?1:0));
        if(editor!=null) textDialog.setOnShowListener(dialog->{ editor.requestFocus(); textDialog.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE); });
        textDialog.show();
    }
    private void commitEditor(Tab tab,EditText editor,int command) {
        if(tab.stopping || !tabs.containsKey(tab.id)) return; tab.title=null;
        NativeEngine.event(tab.id,7,command,0,editor==null?"":editor.getText().toString()); textDialog=null;
    }
    @Override public void browse(String url) {
        Uri uri=Uri.parse(url); if(!"http".equalsIgnoreCase(uri.getScheme()) && !"https".equalsIgnoreCase(uri.getScheme())) return;
        try { startActivity(new Intent(Intent.ACTION_VIEW,uri)); } catch(ActivityNotFoundException ignored) { }
    }
    @Override public void vibrate(int ms) { android.os.Vibrator vibrator=(android.os.Vibrator)getSystemService(VIBRATOR_SERVICE); if(vibrator!=null && ms>0) vibrator.vibrate(VibrationEffect.createOneShot(Math.min(ms,5000),VibrationEffect.DEFAULT_AMPLITUDE)); }
    private void message(String title,String body) { if(!isFinishing() && !isDestroyed()) new AlertDialog.Builder(this).setTitle(title).setMessage(body).setPositiveButton("OK",null).show(); }
    private void showLog() {
        files.execute(()->{
            String text;
            try(RandomAccessFile file=new RandomAccessFile(new File(getFilesDir(),"runtime.log"),"r")) {
                long offset=Math.max(0,file.length()-240000); file.seek(offset); byte[] data=new byte[(int)(file.length()-offset)]; file.readFully(data); text=new String(data,StandardCharsets.UTF_8);
            } catch(IOException error) { text="Chưa có log."; }
            final String value=text; ui.post(()->{
                TextView view=new TextView(this); view.setText(value); view.setTextIsSelectable(true); view.setTextSize(11); view.setTypeface(android.graphics.Typeface.MONOSPACE);
                ScrollView scroll=new ScrollView(this); scroll.addView(view);
                new AlertDialog.Builder(this).setTitle("Log").setView(scroll).setPositiveButton("Đóng",null).setNeutralButton("Chia sẻ",(d,w)->{
                    Intent share=new Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT,value); startActivity(Intent.createChooser(share,"Chia sẻ log"));
                }).show();
            });
        });
    }
    @Override protected void onResume() { super.onResume(); resumed=true; NativeEngine.listen(this); for(Tab tab:tabs.values()) NativeEngine.event(tab.id,9,0,0,null); }
    @Override protected void onPause() { releaseKeys(); hideKeyboard(); for(Tab tab:tabs.values()) NativeEngine.event(tab.id,8,0,0,null); resumed=false; super.onPause(); }
    @Override protected void onDestroy() {
        if(settingsDialog!=null) { settingsDialog.setOnDismissListener(null);settingsDialog.dismiss();settingsDialog=null; }
        ui.removeCallbacks(poll); dismissEditor(); files.shutdown();
        for(Tab tab:tabs.values()) NativeEngine.closeTab(tab.id);
        NativeEngine.shutdown(); NativeEngine.listen(null);
        super.onDestroy();
    }
    @Override public void onBackPressed() {
        if(keyboard.getVisibility()==View.VISIBLE) { hideKeyboard(); return; }
        if(active!=0) { new AlertDialog.Builder(this).setMessage("Dừng game hiện tại?").setPositiveButton("Dừng",(d,w)->stopActive()).setNegativeButton("Hủy",null).show(); }
        else super.onBackPressed();
    }
    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        if(active==0 || typing.hasFocus() || textDialog!=null) return super.dispatchKeyEvent(event);
        int code=0,key=event.getKeyCode();
        if(key==KeyEvent.KEYCODE_DPAD_UP) code=-1; else if(key==KeyEvent.KEYCODE_DPAD_DOWN) code=-2;
        else if(key==KeyEvent.KEYCODE_DPAD_LEFT) code=-3; else if(key==KeyEvent.KEYCODE_DPAD_RIGHT) code=-4;
        else if(key==KeyEvent.KEYCODE_DPAD_CENTER || key==KeyEvent.KEYCODE_ENTER) code=-5;
        else if(key==KeyEvent.KEYCODE_DEL) code=-8; else if(key>=KeyEvent.KEYCODE_0 && key<=KeyEvent.KEYCODE_9) code='0'+key-KeyEvent.KEYCODE_0;
        else if(key==KeyEvent.KEYCODE_STAR) code='*'; else if(key==KeyEvent.KEYCODE_POUND) code='#';
        else if(event.getUnicodeChar()>0 && !event.isCtrlPressed() && !event.isAltPressed()) code=event.getUnicodeChar();
        if(code==0) return super.dispatchKeyEvent(event);
        NativeEngine.event(active,event.getAction()==KeyEvent.ACTION_UP?2:event.getRepeatCount()>0?3:1,code,0,null); return true;
    }
}
