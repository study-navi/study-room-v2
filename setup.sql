create extension if not exists pgcrypto;

create table if not exists public.classrooms (
  id uuid primary key default gen_random_uuid(),
  code text unique not null check (code = upper(code)),
  name text not null,
  teacher_id text not null default 'teacher',
  password_hash text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.study_records (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  sent_at timestamptz not null default now(),
  study_date date not null default current_date,
  student_name text not null,
  grade text, subject text, start_time text, end_time text,
  minutes integer not null default 0 check (minutes between 0 and 1440),
  focus integer check (focus between 1 and 5),
  achievement integer check (achievement between 1 and 5),
  content text, comment text,
  record_method text not null default 'timer' check (record_method in ('timer','manual'))
);

-- 既存データベースへの列追加（既に列がある場合は何もしません）
alter table public.study_records
  add column if not exists record_method text not null default 'timer';

-- 既存データの初期値を保証（default適用前にnullが残っていた場合の保険）
update public.study_records set record_method = 'timer' where record_method is null;

-- 値の制約（既存DBで列だけ追加された場合に備えて個別に付与）
do $do$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'study_records_record_method_check'
      and conrelid = 'public.study_records'::regclass
  ) then
    alter table public.study_records
      add constraint study_records_record_method_check
      check (record_method in ('timer','manual'));
  end if;
end
$do$;

create table if not exists public.teacher_sessions (
  token uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '12 hours'
);

alter table public.classrooms enable row level security;
alter table public.study_records enable row level security;
alter table public.teacher_sessions enable row level security;
revoke all on public.classrooms, public.study_records, public.teacher_sessions from anon, authenticated;

create or replace function public.study_room_api(p_action text, p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare
  c public.classrooms%rowtype; r public.study_records%rowtype;
  sid uuid; tok uuid; valid_room uuid; rows jsonb;
  v_method text; v_date date;
begin
  select * into c from public.classrooms where code=upper(trim(coalesce(p_data->>'classroomCode','')));
  if not found then return jsonb_build_object('result','error','message','教室コードが違います。'); end if;

  if p_action='teacherLogin' then
    if c.teacher_id=coalesce(p_data->>'teacherId','') and c.password_hash=crypt(coalesce(p_data->>'teacherPass',''),c.password_hash) then
      delete from public.teacher_sessions where expires_at<now();
      insert into public.teacher_sessions(classroom_id) values(c.id) returning token into tok;
      return jsonb_build_object('result','success','session',tok::text,'classroomName',c.name);
    end if;
    return jsonb_build_object('result','error','message','IDまたはパスワードが違います。');
  end if;

  if p_action in ('list','delete') or (p_action='update' and coalesce(p_data->>'session','')<>'') then
    begin tok=(p_data->>'session')::uuid; exception when others then tok=null; end;
    select classroom_id into valid_room from public.teacher_sessions where token=tok and expires_at>now();
    if valid_room is distinct from c.id then return jsonb_build_object('result','error','message','もう一度ログインしてください。'); end if;
  end if;

  if p_action='add' then
    v_method = case when p_data->>'recordMethod'='manual' then 'manual' else 'timer' end;
    v_date = coalesce(nullif(p_data->>'date','')::date, current_date);
    -- 未来の日付は禁止（サーバーのタイムゾーン差を考慮して1日の余裕を許容）
    if v_date > current_date + 1 then
      return jsonb_build_object('result','error','message','未来の日付は選択できません。');
    end if;
    insert into public.study_records(classroom_id,study_date,student_name,grade,subject,start_time,end_time,minutes,focus,achievement,content,comment,record_method)
    values(c.id,v_date,left(coalesce(p_data->>'name',''),100),left(coalesce(p_data->>'grade',''),20),left(coalesce(p_data->>'subject',''),30),left(coalesce(p_data->>'startTime',''),10),left(coalesce(p_data->>'endTime',''),10),coalesce(nullif(p_data->>'minutes','')::int,0),nullif(p_data->>'focus','')::int,nullif(p_data->>'achievement','')::int,left(coalesce(p_data->>'content',''),1000),left(coalesce(p_data->>'comment',''),1000),v_method) returning * into r;
    return jsonb_build_object('result','success','id',r.id::text);
  elsif p_action='update' then
    begin sid=(p_data->>'id')::uuid; exception when others then return jsonb_build_object('result','error','message','記録IDが不正です。'); end;
    -- 先生セッションがない更新（生徒の退室送信）は、退室未入力の仮記録のみ許可します。
    if coalesce(p_data->>'session','')='' then
      perform 1 from public.study_records where id=sid and classroom_id=c.id and coalesce(end_time,'')='';
      if not found then return jsonb_build_object('result','error','message','この記録は更新できません。'); end if;
    end if;
    update public.study_records set study_date=coalesce(nullif(p_data->>'date','')::date,study_date),student_name=left(coalesce(p_data->>'name',student_name),100),grade=left(coalesce(p_data->>'grade',grade),20),subject=left(coalesce(p_data->>'subject',subject),30),start_time=left(coalesce(p_data->>'startTime',start_time),10),end_time=left(coalesce(p_data->>'endTime',end_time),10),minutes=coalesce(nullif(p_data->>'minutes','')::int,minutes),focus=nullif(p_data->>'focus','')::int,achievement=nullif(p_data->>'achievement','')::int,content=left(coalesce(p_data->>'content',content),1000),comment=left(coalesce(p_data->>'comment',comment),1000) where id=sid and classroom_id=c.id returning * into r;
    if not found then return jsonb_build_object('result','error','message','記録が見つかりません。'); end if;
    return jsonb_build_object('result','success','id',r.id::text);
  elsif p_action='delete' then
    delete from public.study_records where id=(p_data->>'id')::uuid and classroom_id=c.id;
    return jsonb_build_object('result','success');
  elsif p_action='list' then
    select coalesce(jsonb_agg(jsonb_build_object('ID',id::text,'送信日時',sent_at,'日付',study_date,'名前',student_name,'学年',grade,'科目',subject,'入室時間',start_time,'退室時間',end_time,'自習分数',minutes,'集中度',focus,'達成度',achievement,'学習内容',content,'コメント',comment,'記録方法',record_method) order by sent_at desc),'[]'::jsonb) into rows from public.study_records where classroom_id=c.id;
    return jsonb_build_object('result','success','records',rows,'classroomName',c.name);
  elsif p_action='ping' then return jsonb_build_object('result','success');
  end if;
  return jsonb_build_object('result','error','message','未対応の操作です。');
exception when others then return jsonb_build_object('result','error','message','保存処理でエラーが発生しました。');
end; $$;

grant execute on function public.study_room_api(text,jsonb) to anon, authenticated;

-- 最初の教室。コード・教室名・ID・パスワードを書き換えて実行してください。
insert into public.classrooms(code,name,teacher_id,password_hash)
values('SAMPLE01','サンプル教室','teacher',crypt('change-me',gen_salt('bf')))
on conflict(code) do nothing;
