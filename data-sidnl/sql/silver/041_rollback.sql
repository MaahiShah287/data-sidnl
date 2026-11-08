-- Restores silver.refresh_brand to its pre-041 definition (latest backup tagged pre_041).
do $r$ declare d text; begin
  select definition into d from silver.function_backup where fn='silver.refresh_brand(text,boolean)' and tag='pre_041' order by saved_at desc limit 1;
  if d is null then raise exception 'no pre_041 backup'; end if;
  execute d;
end $r$;
