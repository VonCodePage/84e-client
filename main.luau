local init={cache={}}do do local __modImpl=function()local Scope={}
Scope.__index=Scope

function Scope.new(name)
return setmetatable({Name=name or"scope",Alive=true,Items={},Order={},Errors={},Generation=0},Scope)
end local dispose=function(

value, cleanup)
if cleanup then return cleanup(value)end
if type(value)=="function"then return value()end
if value.Disconnect then return value:Disconnect()end
if value.Destroy then return value:Destroy()end
if value.Remove then return value:Remove()end
error"resource has no cleanup method"end


function Scope.Own(self,value,cleanup)
if not self.Alive then
local ok,err=pcall(dispose,value,cleanup)
if not ok then
table.insert(self.Errors,tostring(err):sub(1,500))
if#self.Errors>50 then table.remove(self.Errors,1)end
end
return value
end
if self.Items[value]~=nil then return value end
self.Items[value]=cleanup or false
table.insert(self.Order,value)
return value
end

function Scope.Release(self,value,destroy)
local cleanup=self.Items[value]
if cleanup==nil then return end
self.Items[value]=nil
for index,item in self.Order do
if item==value then table.remove(self.Order,index)break end
end
if destroy then
local ok,err=pcall(dispose,value,cleanup or nil)
if not ok then
table.insert(self.Errors,tostring(err):sub(1,500))
if#self.Errors>50 then table.remove(self.Errors,1)end
end
end
end

function Scope.Delay(self,seconds,callback)
local generation=self.Generation
task.delay(seconds,function()
if self.Alive and generation==self.Generation then callback()end
end)
end

function Scope.Count(self)
return#self.Order
end

function Scope.Stop(self)
if not self.Alive then return self.Errors end
self.Alive=false
self.Generation=self.Generation+1
while#self.Order>0 do self:Release(self.Order[#self.Order],true)end
return self.Errors
end

return Scope end function init.a()local v=init.cache.a if not v then v={c=__modImpl()}init.cache.a=v end return v.c end end do local __modImpl=function()

local Runtime={
Alive=true,
Cleanups={},
Errors={},
ErrorOrder={},
Metrics={},
Validators={},
Log={},
Resources=init.a().new"runtime resources",
}

function Runtime.Sanitize(value)
return tostring(value):sub(1,1000):gsub("https?://[^%s]+","[url]")
:gsub("[A-Za-z]:[\\/][^\n]+","[path]")
:gsub("[Tt]oken[%s:=]+[%w_%-%.]+","token=[redacted]")
end

function Runtime.Own(value,cleanup)return Runtime.Resources:Own(value,cleanup)end
function Runtime.Release(value,destroy)return Runtime.Resources:Release(value,destroy)end

function Runtime.Checkpoint()
local owned={}
for value in Runtime.Resources.Items do owned[value]=true end
return{CleanupCount=#Runtime.Cleanups,Owned=owned}
end

function Runtime.Rollback(checkpoint)
for index=#Runtime.Cleanups,checkpoint.CleanupCount+1,-1 do
local ok,err=pcall(table.remove(Runtime.Cleanups,index))
if not ok then Runtime.Record("initialization cleanup",err)end
end
for _,value in table.clone(Runtime.Resources.Order)do
if not checkpoint.Owned[value]then Runtime.Resources:Release(value,true)end
end
end

function Runtime.RegisterValidator(name,validator)
assert(type(validator)=="function","validator required")
Runtime.Validators[name]=validator
end

function Runtime.Recover(name)
local metric,validator=Runtime.Metrics[name],Runtime.Validators[name]
if not Runtime.Alive then return false,"session stopped"end
if not metric then return false,"unknown component"end
if not validator then return false,"no dependency validator registered"end
local ok,ready=pcall(validator)
if not ok or not ready then return false,"dependencies unavailable"end
metric.Failures=0 metric.Suspended=false
return true
end

function Runtime.Snapshot()
local components={}
for name,metric in Runtime.Metrics do
local samples=table.clone(metric.Samples or{})
table.sort(samples)
table.insert(components,{Name=name,Count=metric.Count,Suspended=metric.Suspended,
LastMs=metric.LastMs,MaxMs=metric.MaxMs,P95Ms=samples[math.max(1,math.ceil(#samples*0.95))]or 0})
end
table.sort(components,function(a,b)return a.Name<b.Name end)
local resourceKinds={}
for resource in Runtime.Resources.Items do
local kind=typeof(resource)
resourceKinds[kind]=(resourceKinds[kind]or 0)+1
end
local ui=Runtime.Library
local uiCounts=ui and{RegistryEntries=#ui.Registry,RetainedSignals=#ui.Signals}or nil
return{Version="2.6.1 Potassium",Alive=Runtime.Alive,ResourceCount=Runtime.Resources:Count(),
ResourceKinds=resourceKinds,UI=uiCounts,
Components=components,Log=(function()
local result={}
for _,item in Runtime.Log do table.insert(result,table.clone(item))end
return result
end)()}
end

function Runtime.Record(name,err)
local entry=Runtime.Errors[name]
if not entry then
if#Runtime.ErrorOrder>=50 then
Runtime.Errors[table.remove(Runtime.ErrorOrder,1)]=nil
end
entry={Count=0,Last="",Time=0}
Runtime.Errors[name]=entry
table.insert(Runtime.ErrorOrder,name)
end
entry.Count=entry.Count+1
entry.Last=Runtime.Sanitize(err)
entry.Time=os.clock()
local last=Runtime.Log[#Runtime.Log]
if last and last.Name==name and last.Message==entry.Last then
last.Count=last.Count+1 last.Time=entry.Time
else
table.insert(Runtime.Log,{Name=name,Message=entry.Last,Count=1,Time=entry.Time})
if#Runtime.Log>100 then table.remove(Runtime.Log,1)end
end
if entry.Count==1 then warn(name..": "..entry.Last)end
end

function Runtime.Add(cleanup)
assert(type(cleanup)=="function","cleanup must be a function")
if not Runtime.Alive then
local ok,err=pcall(cleanup)
if not ok then Runtime.Record("late cleanup",err)end
return
end
table.insert(Runtime.Cleanups,cleanup)
end

function Runtime.Give(connection)
Runtime.Add(function()connection:Disconnect()end)
return connection
end

function Runtime.Update(name,callback,...)
if not Runtime.Alive then return false end
local metric=Runtime.Metrics[name]
if not metric then
metric={Count=0,Failures=0,LastMs=0,MaxMs=0,Suspended=false,Samples={}}
Runtime.Metrics[name]=metric
end
if metric.Suspended then return false end
local start,
ok,err=os.clock(),pcall(callback,...)
metric.Count=metric.Count+1
metric.LastMs=(os.clock()-start)*1000
metric.MaxMs=math.max(metric.MaxMs,metric.LastMs)
table.insert(metric.Samples,metric.LastMs)
if#metric.Samples>64 then table.remove(metric.Samples,1)end
if ok then
metric.Failures=0
else
metric.Failures=metric.Failures+1
metric.Suspended=metric.Failures>=3
Runtime.Record(name,err)
end
return ok
end

function Runtime.Stop()
if not Runtime.Alive then return end
Runtime.Alive=false
for index=#Runtime.Cleanups,1,-1 do
local callback=table.remove(Runtime.Cleanups,index)
local ok,err=pcall(callback)
if not ok then Runtime.Record("cleanup",err)end
end
for _,err in Runtime.Resources:Stop()do Runtime.Record("resource cleanup",err)end
end

return Runtime end function init.b()local v=init.cache.b if not v then v={c=__modImpl()}init.cache.b=v end return v.c end end do local __modImpl=function()

local Storage,
writing={},{}

function Storage.ValidName(name)
return type(name)=="string"and#name>=1 and#name<=64
and name:match"^[%w_][%w_ %-]*$"~=nil
and name:sub(-1)~=" "
and not name:upper():match"^CON$"
and not name:upper():match"^PRN$"
and not name:upper():match"^AUX$"
and not name:upper():match"^NUL$"
and not name:upper():match"^COM%d$"
and not name:upper():match"^LPT%d$"
end

function Storage.Finite(value)
return type(value)=="number"and value==value and math.abs(value)<math.huge
end

function Storage.Exists(path)
return pcall(function()return isfile(path)end)
end

function Storage.Read(path)
local ok,value=pcall(function()
return readfile(path)
end)
return ok,value
end

function Storage.MakeFolders(folder)
local ok,err=pcall(function()
local components=string.split(folder,"/")
for index=1,#components do
local path=table.concat(components,"/",1,index)
if not isfolder(path)then
makefolder(path)
end
end
end)
return ok,err
end

function Storage.Write(path,contents)
if type(path)~="string"or type(contents)~="string"then return false,"invalid write request"end
if writing[path]then return false,"write already in progress"end
writing[path]=true
local
existed,
destinationTouched,oldContents=false,false
local ok,err=pcall(function()
existed=isfile(path)
if existed then
oldContents=readfile(path)
end
local temporary=path..".tmp"
writefile(temporary,contents)
assert(readfile(temporary)==contents,"temporary write verification failed")
if existed then
writefile(path..".bak",oldContents)
end
destinationTouched=true
writefile(path,contents)
assert(readfile(path)==contents,"write verification failed")
end)
if not ok and destinationTouched then
local restored,restoreError=pcall(function()
if existed and oldContents~=nil then
writefile(path,oldContents)
assert(readfile(path)==oldContents,"restore verification failed")
elseif not existed then
if isfile(path)then delfile(path)end
end
end)
if not restored then err=tostring(err).."; restoration failed: "..tostring(restoreError)end
end
pcall(function()
if isfile(path..".tmp")then delfile(path..".tmp")end
end)
writing[path]=nil
if ok then return true,nil end
return false,tostring(err)
end

function Storage.List(folder,extension)
local ok,entries=pcall(listfiles,folder)
if not ok then return false,tostring(entries)end
local result={}
for _,path in entries do
local name=path:gsub("\\","/"):match"([^/]+)$"
if name and name:sub(-#extension)==extension then
local stem=name:sub(1,-#extension-1)
if Storage.ValidName(stem)then table.insert(result,stem)end
end
end
table.sort(result)
return true,result
end

return Storage end function init.c()local v=init.cache.c if not v then v={c=__modImpl()}init.cache.c=v end return v.c end end do local __modImpl=function()

return{["Tahoma.ttf"]={URL="https://raw.githubusercontent.com/sametexe001/luas/a77983d774765693e02f8f661de2930cd818eec0/fonts/windows-xp-tahoma.ttf",SHA256="a1faf828b79950f1e18c1cfb2ad02e57ba88799a0790831ab9bd25541f602c10",Bytes=293464,Format="ttf"},["discord.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/discord.wav",SHA256="4be7788d8ebe992faf2ee7928b476f21c616077a87c0ba6207960ad5a43782bc",Bytes=18522,Format="wav"},["mcbow.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/mcbow.wav",SHA256="cad86bab34b5dc42d63e703d71bcba15dd412287a89132a6549ff6c169f9c0b0",Bytes=68098,Format="wav"},["minecraft.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/minecraft.wav",SHA256="07c943330a147af76718eb2a56fcb2c2191e4e735409cf35df884972afa0ecc4",Bytes=23642,Format="wav"},["minecraft_xp.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/minecraft_xp.wav",SHA256="cff7bd4aab04f0dbb3af4a1d30cd031a21fd1026ca883c4d498e7f1989a536b3",Bytes=42074,Format="wav"},["neverlose.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/neverlose.wav",SHA256="6115f903005dc34586981af698043fb67b3b33553daf95cdb502b563413e9f83",Bytes=152168,Format="wav"},["rust_headshot.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/rust_headshot.wav",SHA256="fa4f8fa5ea0700e28f5a06be182664bf1f7fa36b7f171b9ca292bbdde22daeff",Bytes=68340,Format="wav"},["skeet.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/skeet.wav",SHA256="6132b9a29a2de0edccebe27223d23e8a8264faf8c07f62b35b3e1eae0dc952b4",Bytes=41620,Format="wav"},["stapler.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/stapler.wav",SHA256="170d246b840032663828a5abbb299fd6d9a7c486a743894d4321df883e679425",Bytes=27724,Format="wav"},["shooting_star.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/shooting_star.wav",SHA256="ae42e5154195058cdc7a8a7e9bab451598fb5c4422cbd73d206d03d0e8d95a89",Bytes=294990,Format="wav"},["bubble.wav"]={URL="https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/bubble.wav",SHA256="c6b25c60f50838761839970a66f7bf2766659f953aa7759160ce558eb6cd7b5a",Bytes=32812,Format="wav"}}end function init.d()local v=init.cache.d if not v then v={c=__modImpl()}init.cache.d=v end return v.c end end do local __modImpl=function()

local Storage,
Manifest,
Assets=init.c(),init.d(),{Ready={},Failed={},Pending={},Order={},MaxEntries=64,MaxBytes=2097152}local validate=function(

path, data, entry)
assert(type(data)=="string"and#data>0 and#data<=Assets.MaxBytes,"invalid asset size")
if path:sub(-4):lower()==".wav"then
assert(data:sub(1,4)=="RIFF"and data:sub(9,12)=="WAVE","invalid WAV header")
elseif path:sub(-4):lower()==".ttf"then
assert(data:sub(1,4)==string.char(0,1,0,0)or data:sub(1,4)=="true","invalid TrueType header")
end
if entry then
assert(#data==entry.Bytes,"pinned asset size mismatch")
local hash=crypt and crypt.hash
if type(hash)=="function"then
local digest=hash(data,"sha256")
assert(type(digest)=="string"and digest:lower()==entry.SHA256,"asset checksum mismatch")
end
end end


function Assets.ValidPath(path)
if type(path)~="string"or path:sub(1,18)~="84e Client/assets/"or path:find("..",1,true)or path:find("\\",1,true)then return false end
if#path>240 then return false end
local relative=path:sub(19)
if relative:find("//",1,true)then return false end
local components=string.split(relative,"/")
for index=1,#components-1 do
if not Storage.ValidName(components[index])then return false end
end
local name=path:match"([^/]+)$"
if not name then return false end
local stem,extension=name:match"^(.*)%.([%w]+)$"
return stem~=nil and Storage.ValidName(stem)and(extension=="wav"or extension=="ttf")
end local touch=function(

path)
if not table.find(Assets.Order,path)then table.insert(Assets.Order,path)end
while#Assets.Order>Assets.MaxEntries do
local old=table.remove(Assets.Order,1)
Assets.Ready[old]=nil Assets.Failed[old]=nil
end end


function Assets.GetLocal(path)
if not Assets.ValidPath(path)then return nil,"invalid local asset path"end
local ok,exists=Storage.Exists(path)
if not ok then return nil,tostring(exists)end
if not exists then return nil,"local asset is unavailable"end
return Assets.Get(path)
end

function Assets.Get(path,url)
if not Assets.ValidPath(path)then return nil,"asset path is outside the managed media directory"end
local entry=Manifest[path:match"([^/]+)$"]
if url and(not entry or url~=entry.URL)then return nil,"remote asset is not in the pinned manifest"end
if Assets.Ready[path]then return Assets.Ready[path]end
if Assets.Pending[path]then return nil,"asset is loading"end
local failed=Assets.Failed[path]
if failed and os.clock()<failed.NextTry then return nil,failed.Message end
touch(path)
Assets.Pending[path]=true
local ok,asset=pcall(function()
local data
if isfile(path)then
data=readfile(path)
local valid=pcall(validate,path,data,entry)
if not valid and entry and url then
local replacement=game:HttpGet(entry.URL)
validate(path,replacement,entry)
local saved,saveError=Storage.Write(path,replacement)
assert(saved,saveError)
data=replacement
end
else
assert(entry and url,"local asset is unavailable")
local parent=path:match"^(.*)/[^/]+$"
local made,folderError=Storage.MakeFolders(parent)
assert(made,folderError)
data=game:HttpGet(entry.URL)
validate(path,data,entry)
local saved,saveError=Storage.Write(path,data)
assert(saved,saveError)
end
validate(path,data,entry)
local handle=getcustomasset(path)
assert(type(handle)=="string"and#handle>0,"invalid custom asset handle")
return handle
end)
Assets.Pending[path]=nil
if not ok then
local count=failed and failed.Count+1 or 1
Assets.Failed[path]={Message=tostring(asset),Count=count,NextTry=os.clock()+math.min(30,2^math.min(count,5))}
return nil,tostring(asset)
end
Assets.Failed[path]=nil Assets.Ready[path]=asset
return asset
end

function Assets.Invalidate(path,deleteFile)
if not Assets.ValidPath(path)then return false,"invalid asset path"end
if Assets.Pending[path]then return false,"asset is loading"end
if deleteFile then
local ok,err=pcall(function()if isfile(path)then delfile(path)end end)
if not ok then return false,tostring(err)end
end
Assets.Ready[path]=nil Assets.Failed[path]=nil
return true
end

return Assets end function init.e()local v=init.cache.e if not v then v={c=__modImpl()}init.cache.e=v end return v.c end end do local __modImpl=function()

return init.e()end function init.f()local v=init.cache.f if not v then v={c=__modImpl()}init.cache.f=v end return v.c end end do local __modImpl=function()local Preflight={Version="2.6.1 Potassium",Snapshot="Barraux 2266 / 2026-08-15"}

function Preflight.Check()
local rows={}local add, 



env=function(name, required, available, reason)table.insert(rows,{Name=name,Required=required,Available=available==true,Reason=reason,Behavior="not tested"})end, type(getgenv)=="function"and getgenv()or{}
for _,name in{"cloneref","getloadedmodules","getgc","filtergc","hookfunction"}do
add(name,true,type(env[name])=="function","Required by existing game integration")
end
add("debug introspection",true,type(debug)=="table"and type(debug.getupvalue)=="function"and type(debug.getupvalues)=="function"and type(debug.getinfo)=="function","Existing private module integration")
add("drawings",true,Drawing~=nil and type(Drawing.new)=="function","Existing visual renderer")
add("local storage",false,type(readfile)=="function"and type(writefile)=="function"and type(isfile)=="function"and type(isfolder)=="function"and type(makefolder)=="function"and type(listfiles)=="function"and type(delfile)=="function","Profiles unavailable without file APIs")
add("custom media",false,type(getcustomasset)=="function","Built-in font and default audio remain usable")
add("camera",false,workspace.CurrentCamera~=nil,"Waiting for camera")
local ready=true
for _,row in rows do if row.Required and not row.Available then ready=false end end
return ready,rows
end

function Preflight.Executor()
local env=type(getgenv)=="function"and getgenv()or{}
local identify=env.identifyexecutor or identifyexecutor
if type(identify)~="function"then return{Name="unknown",Version="unknown",Verified=false}end
local ok,name,version=pcall(identify)
return{Name=ok and type(name)=="string"and name or"unknown",
Version=ok and type(version)=="string"and version or"unknown",Verified=false}
end

function Preflight.Describe()
local ready,rows=Preflight.Check()
local executor=Preflight.Executor()
local lines={Preflight.Version,"Executor: "..executor.Name.." / "..executor.Version,"Presence checks only; runtime behavior unverified",Preflight.Snapshot,ready and"Required capabilities present"or"Game integration unavailable"}
for _,row in rows do table.insert(lines,row.Name..": "..(row.Available and"available"or"unavailable").." — "..row.Reason)end
return table.concat(lines,"\n"),ready
end

return Preflight end function init.g()local v=init.cache.g if not v then v={c=__modImpl()}init.cache.g=v end return v.c end end do local __modImpl=function()

local Navigation={Entries={},Focused=nil}

local function copy(value)
if type(value)~="table"then return value end
local result={}
for key,item in value do result[key]=copy(item)end
return result
end

function Navigation.Register(id,object,info,group)
local tab=group and(group.OwnerTab or(group.Metadata and group.Metadata.Tab))
local row={Id=id,Object=object,Label=info.Text or id,Group=group,
Tab=tab,Type=object.Type,Default=copy(object.Value),Mode=object.Mode,
Transparency=object.Transparency,SearchText=(id.." "..(info.Text or"").." "..(group and group.Name or"")):lower()}
Navigation.Entries[id]=row
object.Metadata=row
return row
end

function Navigation.Search(query)
query=tostring(query or""):lower()
local result={}
for _,row in Navigation.Entries do
local found=true
for term in query:gmatch"%S+"do
if not row.SearchText:find(term,1,true)then found=false break end
end
if found then table.insert(result,row)end
end
table.sort(result,function(a,b)return a.Id<b.Id end)
return result
end

function Navigation.Focus(id)
local row=Navigation.Entries[id]
if not row then return false,"unknown setting"end
local control=row.Object.FocusObject or row.Object.TextLabel or row.Object.Container
if not control then return false,"setting has no focus control"end
local ok,err=pcall(function()
if row.Tab then row.Tab:ShowTab()end
if row.Group and row.Group.Show then row.Group:Show()end
control.Selectable=true
game:GetService"GuiService".SelectedObject=control
if control:IsA"TextBox"then control:CaptureFocus()end
local parent=control.Parent
while parent do
if parent:IsA"ScrollingFrame"then
parent.CanvasPosition=Vector2.new(0,math.max(0,control.AbsolutePosition.Y-parent.AbsolutePosition.Y+parent.CanvasPosition.Y-20))
break
end
parent=parent.Parent
end
end)
if not ok then return false,tostring(err)end
Navigation.Focused=id
return true
end

function Navigation.Stop()
local row=Navigation.Entries[Navigation.Focused]
pcall(function()
local service,
control=game:GetService"GuiService",row and(row.Object.FocusObject or row.Object.TextLabel or row.Object.Container)
if control and service.SelectedObject==control then service.SelectedObject=nil end
end)
table.clear(Navigation.Entries)
Navigation.Focused=nil
end

function Navigation.Reset(id)
local row=Navigation.Entries[id]
if not row then return false,"unknown setting"end
local object,value=row.Object,copy(row.Default)
local ok,err=pcall(function()
if row.Type=="ColorPicker"then object:SetValueRGB(value,row.Transparency)
elseif row.Type=="KeyPicker"then object:SetValue{value,row.Mode}
else object:SetValue(value)end
end)
return ok,err
end

function Navigation.ResetTab(tab)
local failed,
rows,
priority={},Navigation.Search"",{AllowUnsafeFeatures=0,ChantSpamGender=1,ChantSpamNation=2,ChantSpamSet=3}
table.sort(rows,function(a,b)
local pa,
pb=priority[a.Id]or(a.Type=="Toggle"and 20 or 10),priority[b.Id]or(b.Type=="Toggle"and 20 or 10)
return pa==pb and a.Id<b.Id or pa<pb
end)
for _,row in rows do
local id=row.Id
if row.Tab==tab then
local ok,err=Navigation.Reset(id)
if not ok then table.insert(failed,id..": "..tostring(err))end
end
end
return#failed==0,failed
end

function Navigation.Conflicts()
local keys,result={},{}
for id,row in Navigation.Entries do
local object=row.Object
if row.Type=="KeyPicker"and object.Value~="-"and object.Value~=""and object.Mode~="Always"then
local key=object.Value
keys[key]=keys[key]or{}
table.insert(keys[key],id.." ("..object.Mode..")")
end
end
for key,names in keys do
if#names>1 then table.sort(names)table.insert(result,key..": "..table.concat(names,", "))end
end
table.sort(result)
return result
end

function Navigation.Step(direction)
local rows=Navigation.Search""
if#rows==0 then return end
local index=0
for i,row in rows do if row.Id==Navigation.Focused then index=i break end end
Navigation.Focus(rows[((index-1+direction)%#rows)+1].Id)
end

function Navigation.Activate(direction)
local row=Navigation.Entries[Navigation.Focused]
if not row then return end
local object=row.Object
if row.Type=="Toggle"then object:SetValue(not object.Value)
elseif row.Type=="Slider"then object:SetValue(object.Value+(direction or 1)*10^-object.Rounding)
elseif row.Type=="Dropdown"and not object.Multi and#object.Values>0 then
local index=table.find(object.Values,object.Value)or 0
object:SetValue(object.Values[((index-1+(direction or 1))%#object.Values)+1])
elseif row.Type=="ColorPicker"then object:Show()
elseif row.Type=="Input"then Navigation.Focus(row.Id)end
end

return Navigation end function init.h()local v=init.cache.h if not v then v={c=__modImpl()}init.cache.h=v end return v.c end end do local __modImpl=function()




local Assets,
Runtime,
Navigation,
TahomaFont=init.f(),init.b(),(init.h())
local FontAsset=Assets.GetLocal"84e Client/assets/Tahoma.ttf"
if FontAsset then
local Storage=init.c()
local ok,err=pcall(function()
local descriptor=game:GetService"HttpService":JSONEncode{
name="Tahoma",
faces={{name="Regular",weight=400,style="normal",assetId=FontAsset}},
}
local saved,message=Storage.Write("84e Client/assets/Tahoma.font",descriptor)
assert(saved,message)
TahomaFont=Font.new(getcustomasset"84e Client/assets/Tahoma.font",Enum.FontWeight.Regular)
end)
if not ok then Runtime.Record("font",err)end
end

local InputService,
TextService,
Teams,
Players,
RunService,
TweenService=game:GetService"UserInputService",game:GetService"TextService",game:GetService"Teams",game:GetService"Players",game:GetService"RunService",game:GetService"TweenService"
local RenderStepped,
LocalPlayer=RunService.RenderStepped,Players.LocalPlayer
local Mouse,

PlayerGui=LocalPlayer:GetMouse(),LocalPlayer:FindFirstChildOfClass"PlayerGui"or LocalPlayer:WaitForChild("PlayerGui",10)
assert(PlayerGui and PlayerGui:IsA"PlayerGui","PlayerGui unavailable after 10 seconds")

local ScreenGui=Runtime.Own(Instance.new"ScreenGui")

ScreenGui.ZIndexBehavior=Enum.ZIndexBehavior.Global
ScreenGui.ResetOnSpawn=false
ScreenGui.Parent=PlayerGui

local Toggles,
Options={},{}

getgenv().GlobalFont="84e Client/assets/Tahoma.font"
getgenv().Toggles=Toggles
getgenv().Options=Options

local Library,



































RainbowStep,
Hue={Registry={},RegistryMap={},HudRegistry={},FontColor=Color3.fromRGB(231,234,241),DisabledColor=Color3.fromRGB(65,65,65),MainColor=Color3.fromRGB(25,28,35),BackgroundColor=Color3.fromRGB(17,20,26),AccentColor=Color3.fromRGB(225,77,91),OutlineColor=Color3.fromRGB(48,54,66),RiskColor=Color3.fromRGB(200,50,50),Black=Color3.new(0,0,0),FontFace=TahomaFont or Font.fromEnum(Enum.Font.Code),Font=Enum.Font.Code,AllowRiskyFeatures=false,OpenedFrames={},DependencyBoxes={},Signals={},UnloadCallbacks={},Alive=true,NotifyOnError=true,SaveQueued=false,FontScale=1,ReducedMotion=false,StandardCursor=false,MenuVisible=false,FontBaselines=setmetatable({},{__mode="k"}),ScreenGui=ScreenGui,},0,0

table.insert(
Library.Signals,
RenderStepped:Connect(function(Delta)
RainbowStep=RainbowStep+Delta

if RainbowStep>=(1.6666666666666665E-2)then
RainbowStep=0

Hue=Hue+(2.5E-3)

if Hue>1 then
Hue=0
end

Library.CurrentRainbowHue=Hue
Library.CurrentRainbowColor=Color3.fromHSV(Hue,0.8,1)
end
end)
)local GetPlayersString, GetTeamsString=function()


local PlayerList=Players:GetPlayers()

for i=1,#PlayerList do
PlayerList[i]=PlayerList[i].Name
end

table.sort(PlayerList,function(str1,str2)
return str1<str2
end)

return PlayerList end, function()



local TeamList=Teams:GetTeams()

for i=1,#TeamList do
TeamList[i]=TeamList[i].Name
end

table.sort(TeamList,function(str1,str2)
return str1<str2
end)

return TeamList end


function Library.SafeCallback(self,callback,...)
if not callback or not Library.Alive then return end
local ok,result=xpcall(callback,function(err)
local message=tostring(err)
if type(debug)=="table"and type(debug.traceback)=="function"then
local traced,trace=pcall(debug.traceback,message,2)
if traced and type(trace)=="string"then return trace end
end
return message
end,...)
if not ok then
Runtime.Record("UI callback",result)
if Library.NotifyOnError then
pcall(function()Library:Notify(tostring(result),3)end)
end
if Library.ThrowCallbackErrors then error(result,0)end
end
if ok then return result end
return nil
end

function Library.ResolveKey(self,name)
if type(name)~="string"or name=="-"or name==""then return nil end
if name=="MB1"then return Enum.UserInputType.MouseButton1 end
if name=="MB2"then return Enum.UserInputType.MouseButton2 end
local ok,key=pcall(function()return Enum.KeyCode[name]end)
return ok and key or nil
end

function Library.AttemptSave(self)
if self.SaveManager and self.SaveManager.Previewing then return end
local manager=Library.SaveManager
if not Library.Alive or Library.Unloading or not manager or manager.Loading or not manager.ActiveProfile then return end
manager.Dirty=true
if Library.SaveQueued then return end
Library.SaveQueued=true
local profile,
generation=manager.ActiveProfile,manager.Generation
Library.SaveToken=(Library.SaveToken or 0)+1
local token=Library.SaveToken
task.delay(0.35,function()
if token~=Library.SaveToken then return end
Library.SaveQueued=false
if generation~=manager.Generation then return end
if not Library.Alive or manager.Loading then return end
local ok,err=manager:Save(profile)
if not ok then Runtime.Record("autosave",err)end
end)
end

function Library.Create(self,Class,Properties)
local _Instance=Class

if type(Class)=="string"then
_Instance=Instance.new(Class)
end

Runtime.Own(_Instance)
local ok,err=pcall(function()
for Property,Value in next,Properties do _Instance[Property]=Value end
end)
if not ok then Runtime.Release(_Instance,true)error(err,0)end
if type(Properties.TextSize)=="number"then
Library.FontBaselines[_Instance]={TextSize=Properties.TextSize,Size=_Instance.Size}
_Instance.TextSize=Properties.TextSize*Library.FontScale
end

return _Instance
end

function Library.SetTextScale(self,scale)
assert(type(scale)=="number"and scale==scale,"invalid text scale")
Library.FontScale=math.clamp(scale,0.8,1.5)
for instance,baseline in Library.FontBaselines do
pcall(function()
instance.TextSize=baseline.TextSize*Library.FontScale
local size=baseline.Size
if size and size.Y.Scale==0 and size.Y.Offset>0 then
instance.Size=UDim2.new(size.X.Scale,size.X.Offset,0,math.ceil(size.Y.Offset*Library.FontScale))
end
end)
end
if Library.Window then
for _,tab in Library.Window.Tabs do
for _,group in tab.Groupboxes do group:Resize()end
end
end
end

function Library.IsNavigationKey(self,input)
if Library.CapturingInput then return true end
if not Library.MenuVisible or not Navigation.Focused then return false end
local key=input.KeyCode
return key==Enum.KeyCode.Tab or key==Enum.KeyCode.Left or key==Enum.KeyCode.Right
or key==Enum.KeyCode.Return or key==Enum.KeyCode.Escape
end

function Library.ClosePopups(self)
for frame in Library.OpenedFrames do
pcall(function()frame.Visible=false end)
end
table.clear(Library.OpenedFrames)
end

function Library.ClampPopup(self,frame)
if not workspace.CurrentCamera then return end
local view,
position,size=workspace.CurrentCamera.ViewportSize,frame.AbsolutePosition,frame.AbsoluteSize
local dx,
dy,
old,
scale=math.clamp(position.X,0,math.max(0,view.X-size.X))-position.X,math.clamp(position.Y,0,math.max(0,view.Y-size.Y))-position.Y,frame.Position,Library.ScaleControl and Library.ScaleControl.Scale or 1
frame.Position=UDim2.new(old.X.Scale,old.X.Offset+dx/scale,old.Y.Scale,old.Y.Offset+dy/scale)
end

function Library.ApplyTextStroke(self,Inst)
Inst.TextStrokeTransparency=1

Library:Create("UIStroke",{
Color=Color3.new(0,0,0),
Thickness=1,
LineJoinMode=Enum.LineJoinMode.Miter,
Parent=Inst,
})
end

function Library.CreateLabel(self,Properties,IsHud)
local _Instance=Library:Create("TextLabel",{
BackgroundTransparency=1,
Font=Library.Font,
FontFace=Library.FontFace,
TextColor3=Library.FontColor,
TextSize=12,
TextStrokeTransparency=0,
})

Library:ApplyTextStroke(_Instance)

Library:AddToRegistry(_Instance,{
TextColor3="FontColor",
},IsHud)

return Library:Create(_Instance,Properties)
end

function Library.MakeDraggable(self,Instance,Cutoff)
Instance.Active=true

Instance.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 then
local ObjPos=Vector2.new(Mouse.X-Instance.AbsolutePosition.X,Mouse.Y-Instance.AbsolutePosition.Y)

if ObjPos.Y>(Cutoff or 40)then
return
end

while Library.Alive and InputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)do
Instance.Position=UDim2.new(
0,
Mouse.X-ObjPos.X+(Instance.Size.X.Offset*Instance.AnchorPoint.X),
0,
Mouse.Y-ObjPos.Y+(Instance.Size.Y.Offset*Instance.AnchorPoint.Y)
)

RenderStepped:Wait()
end
end
end)
end

function Library.AddToolTip(self,InfoStr,HoverInstance)
local X,Y=Library:GetTextBounds(InfoStr,Library.FontFace,12)
local Tooltip=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,

Size=UDim2.fromOffset(X+5,Y+4),
ZIndex=100,
Parent=Library.ScreenGui,

Visible=false,
})

local Label=Library:CreateLabel{
Position=UDim2.fromOffset(3,1),
Size=UDim2.fromOffset(X,Y),
TextSize=12,
Text=InfoStr,
TextColor3=Library.FontColor,
TextXAlignment=Enum.TextXAlignment.Left,
ZIndex=Tooltip.ZIndex+1,

Parent=Tooltip,
}

Library:AddToRegistry(Tooltip,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

Library:AddToRegistry(Label,{
TextColor3="FontColor",
})

local IsHovering=false

HoverInstance.MouseEnter:Connect(function()
if Library:MouseIsOverOpenedFrame()then
return
end

IsHovering=true

Tooltip.Position=UDim2.fromOffset(Mouse.X+15,Mouse.Y+12)
Tooltip.Visible=true

while Library.Alive and IsHovering and HoverInstance.Parent do
RunService.Heartbeat:Wait()
Tooltip.Position=UDim2.fromOffset(Mouse.X+15,Mouse.Y+12)
end
end)

HoverInstance.MouseLeave:Connect(function()
IsHovering=false
Tooltip.Visible=false
end)
end

function Library.OnHighlight(self,HighlightInstance,Instance,Properties,PropertiesDefault)
HighlightInstance.MouseEnter:Connect(function()
local Reg=Library.RegistryMap[Instance]

for Property,ColorIdx in next,Properties do
Instance[Property]=Library[ColorIdx]or ColorIdx

if Reg and Reg.Properties[Property]then
Reg.Properties[Property]=ColorIdx
end
end
end)

HighlightInstance.MouseLeave:Connect(function()
local Reg=Library.RegistryMap[Instance]

for Property,ColorIdx in next,PropertiesDefault do
Instance[Property]=Library[ColorIdx]or ColorIdx

if Reg and Reg.Properties[Property]then
Reg.Properties[Property]=ColorIdx
end
end
end)
end

function Library.MouseIsOverOpenedFrame(self)
for Frame,_ in next,Library.OpenedFrames do
local AbsPos,AbsSize=Frame.AbsolutePosition,Frame.AbsoluteSize

if
Mouse.X>=AbsPos.X
and Mouse.X<=AbsPos.X+AbsSize.X
and Mouse.Y>=AbsPos.Y
and Mouse.Y<=AbsPos.Y+AbsSize.Y
then
return true
end
end
end

function Library.IsMouseOverFrame(self,Frame)
local AbsPos,AbsSize=Frame.AbsolutePosition,Frame.AbsoluteSize

if
Mouse.X>=AbsPos.X
and Mouse.X<=AbsPos.X+AbsSize.X
and Mouse.Y>=AbsPos.Y
and Mouse.Y<=AbsPos.Y+AbsSize.Y
then
return true
end
end

function Library.UpdateDependencyBoxes(self)
for _,Depbox in next,Library.DependencyBoxes do
Depbox:Update()
end
end

function Library.MapValue(self,Value,MinA,MaxA,MinB,MaxB)
assert(MaxA~=MinA,"mapping range must be nonzero")
return(1-((Value-MinA)/(MaxA-MinA)))*MinB+((Value-MinA)/(MaxA-MinA))*MaxB
end

function Library.GetTextBounds(self,Text,FontFace,Size,Resolution)
local Params
local ok,Bounds=pcall(function()
Params=Instance.new"GetTextBoundsParams"
Params.Text=Text
Params.Font=FontFace
Params.Size=Size
Params.Width=Resolution and Resolution.X or math.huge
return TextService:GetTextBoundsAsync(Params)
end)
if Params then
local cleaned,cleanupError=pcall(function()Params:Destroy()end)
if not cleaned then Runtime.Record("text measurement cleanup",cleanupError)end
end
if not ok then
Runtime.Record("text measurement",Bounds)
local fallbackOk,fallback=pcall(function()
return TextService:GetTextSize(Text,Size,Library.Font,Vector2.new(Resolution and Resolution.X or 10000,10000))
end)
if not fallbackOk then error("Text measurement unavailable: "..tostring(fallback),0)end
Bounds=fallback
end
return Bounds.X,Bounds.Y
end

function Library.GetDarkerColor(self,Color)
local H,S,V=Color3.toHSV(Color)
return Color3.fromHSV(H,S,V/1.5)
end
Library.AccentColorDark=Library:GetDarkerColor(Library.AccentColor)

function Library.AddToRegistry(self,Instance,Properties,IsHud)
local Idx=#Library.Registry+1
local Data={
Instance=Instance,
Properties=Properties,
Idx=Idx,
}

table.insert(Library.Registry,Data)
Library.RegistryMap[Instance]=Data

if IsHud then
table.insert(Library.HudRegistry,Data)
end
end

function Library.RemoveFromRegistry(self,Instance)
local Data=Library.RegistryMap[Instance]

if Data then
for Idx=#Library.Registry,1,-1 do
if Library.Registry[Idx]==Data then
table.remove(Library.Registry,Idx)
end
end

for Idx=#Library.HudRegistry,1,-1 do
if Library.HudRegistry[Idx]==Data then
table.remove(Library.HudRegistry,Idx)
end
end

Library.RegistryMap[Instance]=nil
end
end

function Library.UpdateColorsUsingRegistry(self)










for Idx,Object in next,Library.Registry do
for Property,ColorIdx in next,Object.Properties do
if type(ColorIdx)=="string"then
Object.Instance[Property]=Library[ColorIdx]
elseif type(ColorIdx)=="function"then
Object.Instance[Property]=ColorIdx()
end
end
end
end

function Library.GiveSignal(self,Signal)
if not Library.Alive then Signal:Disconnect()return end

table.insert(Library.Signals,Signal)
end

function Library.Unload(self)
if not Library.Alive or Library.Unloading then return end
Library.Unloading=true
if Library.SaveManager and Library.SaveManager.ActiveProfile and not Library.SaveManager.Previewing then
local ok,err=Library.SaveManager:Save()
if not ok then Runtime.Record("final save",err)end
end
Navigation.Stop()
if Library.SaveManager then Library.SaveManager:InvalidateQueue()end
for index=#Library.UnloadCallbacks,1,-1 do
local ok,err=pcall(table.remove(Library.UnloadCallbacks,index))
if not ok then Runtime.Record("UI unload",err)end
end
Library.Alive=false
Runtime.Stop()
local blur=Library.MenuBlur
if blur then pcall(function()blur:Destroy()end)end
if Library.OriginalMouseIconEnabled~=nil then
InputService.MouseIconEnabled=Library.OriginalMouseIconEnabled
end
local destroyed,destroyError=pcall(function()ScreenGui:Destroy()end)
if not destroyed then Runtime.Record("screen cleanup",destroyError)end
for index=#Library.Signals,1,-1 do
pcall(function()table.remove(Library.Signals,index):Disconnect()end)
end
table.clear(Library.Registry)
table.clear(Library.RegistryMap)
table.clear(Library.HudRegistry)
table.clear(Library.OpenedFrames)
table.clear(Library.DependencyBoxes)
table.clear(Options)
table.clear(Toggles)
if getgenv().Library==Library then getgenv().Library=nil end
end

function Library.OnUnload(self,callback)
assert(type(callback)=="function","unload callback must be a function")
table.insert(Library.UnloadCallbacks,callback)
end

Library:GiveSignal(ScreenGui.DescendantRemoving:Connect(function(Instance)
Runtime.Release(Instance,false)
if Library.RegistryMap[Instance]then
Library:RemoveFromRegistry(Instance)
end
end))

local BaseAddons={}

do
local Funcs={}

function Funcs.AddColorPicker(self,Idx,Info)
local ToggleLabel=self.TextLabel


assert(Info.Default,"AddColorPicker: Missing default value.")

local ColorPicker={
Value=Info.Default,
Transparency=Info.Transparency or 0,
Type="ColorPicker",
Title=type(Info.Title)=="string"and Info.Title or"Color picker",
Callback=Info.Callback or function(Color)end,
}

function ColorPicker.SetHSVFromRGB(self,Color)
local H,S,V=Color3.toHSV(Color)

ColorPicker.Hue=H
ColorPicker.Sat=S
ColorPicker.Vib=V
end

ColorPicker:SetHSVFromRGB(ColorPicker.Value)

local DisplayFrame=Library:Create("Frame",{
BackgroundColor3=ColorPicker.Value,
BorderColor3=Library:GetDarkerColor(ColorPicker.Value),
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(0,28,0,14),
ZIndex=6,
Parent=ToggleLabel,
})local


CheckerFrame, 













PickerFrameOuter=Library:Create("ImageLabel",{BorderSizePixel=0,Size=UDim2.new(0,27,0,13),ZIndex=5,Image="http://www.roblox.com/asset/?id=12977615774",Visible=not not Info.Transparency,Parent=DisplayFrame,}), Library:Create("Frame",{
Name="Color",
BackgroundColor3=Color3.new(1,1,1),
BorderColor3=Color3.new(0,0,0),
Position=UDim2.fromOffset(DisplayFrame.AbsolutePosition.X,DisplayFrame.AbsolutePosition.Y+18),
Size=UDim2.fromOffset(230,Info.Transparency and 271 or 253),
Visible=false,
ZIndex=15,
Parent=ScreenGui,
})

DisplayFrame:GetPropertyChangedSignal"AbsolutePosition":Connect(function()
PickerFrameOuter.Position=
UDim2.fromOffset(DisplayFrame.AbsolutePosition.X,DisplayFrame.AbsolutePosition.Y+18)
end)

local PickerFrameInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=16,
Parent=PickerFrameOuter,
})

local Highlight,







SatVibMapOuter=Library:Create("Frame",{BackgroundColor3=Library.AccentColor,BorderSizePixel=0,Size=UDim2.new(1,0,0,2),ZIndex=17,Parent=PickerFrameInner,}),Library:Create("Frame",{
BorderColor3=Color3.new(0,0,0),
Position=UDim2.new(0,4,0,25),
Size=UDim2.new(0,200,0,200),
ZIndex=17,
Parent=PickerFrameInner,
})

local SatVibMapInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=18,
Parent=SatVibMapOuter,
})

local SatVibMap=Library:Create("ImageLabel",{
BorderSizePixel=0,
Size=UDim2.new(1,0,1,0),
ZIndex=18,
Image="rbxassetid://4155801252",
Parent=SatVibMapInner,
})

local CursorOuter=Library:Create("ImageLabel",{
AnchorPoint=Vector2.new(0.5,0.5),
Size=UDim2.new(0,6,0,6),
BackgroundTransparency=1,
Image="http://www.roblox.com/asset/?id=9619665977",
ImageColor3=Color3.new(0,0,0),
ZIndex=19,
Parent=SatVibMap,
})local

CursorInner, 








HueSelectorOuter=Library:Create("ImageLabel",{Size=UDim2.new(0,CursorOuter.Size.X.Offset-2,0,CursorOuter.Size.Y.Offset-2),Position=UDim2.new(0,1,0,1),BackgroundTransparency=1,Image="http://www.roblox.com/asset/?id=9619665977",ZIndex=20,Parent=CursorOuter,}), Library:Create("Frame",{
BorderColor3=Color3.new(0,0,0),
Position=UDim2.new(0,208,0,25),
Size=UDim2.new(0,15,0,200),
ZIndex=17,
Parent=PickerFrameInner,
})

local HueSelectorInner=Library:Create("Frame",{
BackgroundColor3=Color3.new(1,1,1),
BorderSizePixel=0,
Size=UDim2.new(1,0,1,0),
ZIndex=18,
Parent=HueSelectorOuter,
})

local HueCursor,








HueBoxOuter=Library:Create("Frame",{BackgroundColor3=Color3.new(1,1,1),AnchorPoint=Vector2.new(0,0.5),BorderColor3=Color3.new(0,0,0),Size=UDim2.new(1,0,0,1),ZIndex=18,Parent=HueSelectorInner,}),Library:Create("Frame",{
BorderColor3=Color3.new(0,0,0),
Position=UDim2.fromOffset(4,228),
Size=UDim2.new(0.5,-6,0,20),
ZIndex=18,
Parent=PickerFrameInner,
})

local HueBoxInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=18,
Parent=HueBoxOuter,
})

Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(212,212,212)),
},
Rotation=90,
Parent=HueBoxInner,
})

local HueBox=Library:Create("TextBox",{
BackgroundTransparency=1,
Position=UDim2.new(0,5,0,0),
Size=UDim2.new(1,-5,1,0),
PlaceholderColor3=Color3.fromRGB(190,190,190),
PlaceholderText="Hex color",
Text="#FFFFFF",
TextColor3=Library.FontColor,
TextSize=12,
TextStrokeTransparency=0,
TextXAlignment=Enum.TextXAlignment.Left,
ZIndex=20,
Parent=HueBoxInner,
FontFace=Library.FontFace,
})

Library:ApplyTextStroke(HueBox)

local RgbBoxBase=Library:Create(HueBoxOuter:Clone(),{
Position=UDim2.new(0.5,2,0,228),
Size=UDim2.new(0.5,-6,0,20),
Parent=PickerFrameInner,
})

local RgbBox,






TransparencyBoxOuter,TransparencyBoxInner,TransparencyCursor=(Library:Create(RgbBoxBase.Frame:FindFirstChild"TextBox",{Text="255, 255, 255",PlaceholderText="RGB color",TextColor3=Library.FontColor,FontFace=Library.FontFace,}))

if Info.Transparency then
TransparencyBoxOuter=Library:Create("Frame",{
BorderColor3=Color3.new(0,0,0),
Position=UDim2.fromOffset(4,251),
Size=UDim2.new(1,-8,0,15),
ZIndex=19,
Parent=PickerFrameInner,
})

TransparencyBoxInner=Library:Create("Frame",{
BackgroundColor3=ColorPicker.Value,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=19,
Parent=TransparencyBoxOuter,
})

Library:AddToRegistry(TransparencyBoxInner,{BorderColor3="OutlineColor"})

Library:Create("ImageLabel",{
BackgroundTransparency=1,
Size=UDim2.new(1,0,1,0),
Image="http://www.roblox.com/asset/?id=12978095818",
ZIndex=20,
Parent=TransparencyBoxInner,
})

TransparencyCursor=Library:Create("Frame",{
BackgroundColor3=Color3.new(1,1,1),
AnchorPoint=Vector2.new(0.5,0),
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(0,1,1,0),
ZIndex=21,
Parent=TransparencyBoxInner,
})
end local

DisplayLabel, 











ContextMenu=Library:CreateLabel{Size=UDim2.new(1,0,0,14),Position=UDim2.fromOffset(5,5),TextXAlignment=Enum.TextXAlignment.Left,TextSize=12,Text=ColorPicker.Title,TextWrapped=false,ZIndex=16,Parent=PickerFrameInner,FontFace=Library.FontFace,}, {}

do
ContextMenu.Options={}
ContextMenu.Container=Library:Create("Frame",{
BorderColor3=Color3.new(),
ZIndex=14,

Visible=false,
Parent=ScreenGui,
})

ContextMenu.Inner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.fromScale(1,1),
ZIndex=15,
Parent=ContextMenu.Container,
})

Library:Create("UIListLayout",{
Name="Layout",
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=ContextMenu.Inner,
})

Library:Create("UIPadding",{
Name="Padding",
PaddingLeft=UDim.new(0,4),
Parent=ContextMenu.Inner,
})local updateMenuPosition, updateMenuSize=function()


ContextMenu.Container.Position=UDim2.fromOffset(
(DisplayFrame.AbsolutePosition.X+DisplayFrame.AbsoluteSize.X)+4,
DisplayFrame.AbsolutePosition.Y+1
)end, function()



local menuWidth=75
for i,label in next,ContextMenu.Inner:GetChildren()do
if label:IsA"TextLabel"then
menuWidth=math.max(menuWidth,label.TextBounds.X)
end
end

ContextMenu.Container.Size=
UDim2.fromOffset(menuWidth+8,ContextMenu.Inner.Layout.AbsoluteContentSize.Y+4)end


DisplayFrame:GetPropertyChangedSignal"AbsolutePosition":Connect(updateMenuPosition)
ContextMenu.Inner.Layout:GetPropertyChangedSignal"AbsoluteContentSize":Connect(updateMenuSize)

task.spawn(updateMenuPosition)
task.spawn(updateMenuSize)

Library:AddToRegistry(ContextMenu.Inner,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

function ContextMenu.Show(self)
self.Container.Visible=true
end

function ContextMenu.Hide(self)
self.Container.Visible=false
end

function ContextMenu.AddOption(self,Str,Callback)
if type(Callback)~="function"then
Callback=function()end
end

local Button=Library:CreateLabel{
Active=false,
Size=UDim2.new(1,0,0,15),
TextSize=12,
Text=Str,
ZIndex=16,
Parent=self.Inner,
TextXAlignment=Enum.TextXAlignment.Center,
}

Library:OnHighlight(Button,Button,{TextColor3="AccentColor"},{TextColor3="FontColor"})

Button.InputBegan:Connect(function(Input)
if Input.UserInputType~=Enum.UserInputType.MouseButton1 then
return
end

Callback()
end)
end

ContextMenu:AddOption("Copy color",function()
Library.ColorClipboard=ColorPicker.Value
Library:Notify("Copied color!",2)
end)

ContextMenu:AddOption("Paste color",function()
if not Library.ColorClipboard then
return Library:Notify("You have not copied a color!",2)
end
ColorPicker:SetValueRGB(Library.ColorClipboard)
end)

ContextMenu:AddOption("Copy HEX",function()
pcall(setclipboard,ColorPicker.Value:ToHex())
Library:Notify("Copied hex code to clipboard!",2)
end)

ContextMenu:AddOption("Copy RGB",function()
pcall(
setclipboard,
table.concat({
math.floor(ColorPicker.Value.R*255),
math.floor(ColorPicker.Value.G*255),
math.floor(ColorPicker.Value.B*255),
},", ")
)
Library:Notify("Copied RGB values to clipboard!",2)
end)
end

Library:AddToRegistry(PickerFrameInner,{BackgroundColor3="BackgroundColor",BorderColor3="OutlineColor"})
Library:AddToRegistry(Highlight,{BackgroundColor3="AccentColor"})
Library:AddToRegistry(SatVibMapInner,{BackgroundColor3="BackgroundColor",BorderColor3="OutlineColor"})

Library:AddToRegistry(HueBoxInner,{BackgroundColor3="MainColor",BorderColor3="OutlineColor"})
Library:AddToRegistry(RgbBoxBase.Frame,{BackgroundColor3="MainColor",BorderColor3="OutlineColor"})
Library:AddToRegistry(RgbBox,{TextColor3="FontColor"})
Library:AddToRegistry(HueBox,{TextColor3="FontColor"})

local SequenceTable={}

for Hue=0,1,0.1 do
table.insert(SequenceTable,ColorSequenceKeypoint.new(Hue,Color3.fromHSV(Hue,1,1)))
end

Library:Create("UIGradient",{
Color=ColorSequence.new(SequenceTable),
Rotation=90,
Parent=HueSelectorInner,
})

HueBox.FocusLost:Connect(function(enter)
if enter then
local success,result=pcall(Color3.fromHex,HueBox.Text)
if success and typeof(result)=="Color3"then
ColorPicker.Hue,ColorPicker.Sat,ColorPicker.Vib=Color3.toHSV(result)
end
end

ColorPicker:Display()
end)

RgbBox.FocusLost:Connect(function(enter)
if enter then
local r,g,b=RgbBox.Text:match"(%d+),%s*(%d+),%s*(%d+)"
if r and g and b then
ColorPicker.Hue,ColorPicker.Sat,ColorPicker.Vib=Color3.toHSV(Color3.fromRGB(r,g,b))
end
end

ColorPicker:Display()
end)

function ColorPicker.Display(self)
ColorPicker.Value=Color3.fromHSV(ColorPicker.Hue,ColorPicker.Sat,ColorPicker.Vib)
SatVibMap.BackgroundColor3=Color3.fromHSV(ColorPicker.Hue,1,1)

Library:Create(DisplayFrame,{
BackgroundColor3=ColorPicker.Value,
BackgroundTransparency=ColorPicker.Transparency,
BorderColor3=Library:GetDarkerColor(ColorPicker.Value),
})

if TransparencyBoxInner then
TransparencyBoxInner.BackgroundColor3=ColorPicker.Value
TransparencyCursor.Position=UDim2.new(1-ColorPicker.Transparency,0,0,0)
end

CursorOuter.Position=UDim2.new(ColorPicker.Sat,0,1-ColorPicker.Vib,0)
HueCursor.Position=UDim2.new(0,0,ColorPicker.Hue,0)

HueBox.Text="#"..ColorPicker.Value:ToHex()
RgbBox.Text=table.concat({
math.floor(ColorPicker.Value.R*255),
math.floor(ColorPicker.Value.G*255),
math.floor(ColorPicker.Value.B*255),
},", ")

Library:SafeCallback(ColorPicker.Callback,ColorPicker.Value)
Library:SafeCallback(ColorPicker.Changed,ColorPicker.Value)
end

function ColorPicker.OnChanged(self,Func)
ColorPicker.Changed=Func
Func(ColorPicker.Value)
end

function ColorPicker.Show(self)
for Frame,Val in next,Library.OpenedFrames do
if Frame.Name=="Color"then
Frame.Visible=false
Library.OpenedFrames[Frame]=nil
end
end

PickerFrameOuter.Visible=true
Library.OpenedFrames[PickerFrameOuter]=true
Library:ClampPopup(PickerFrameOuter)
end

function ColorPicker.Hide(self)
PickerFrameOuter.Visible=false
Library.OpenedFrames[PickerFrameOuter]=nil
end

function ColorPicker.SetValue(self,HSV,Transparency)
local Color=Color3.fromHSV(HSV[1],HSV[2],HSV[3])

ColorPicker.Transparency=Transparency or 0
ColorPicker:SetHSVFromRGB(Color)
ColorPicker:Display()
end

function ColorPicker.SetValueRGB(self,Color,Transparency)
ColorPicker.Transparency=Transparency or 0
ColorPicker:SetHSVFromRGB(Color)
ColorPicker:Display()
end

SatVibMap.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 then
while Library.Alive and InputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)do
local MinX=SatVibMap.AbsolutePosition.X
local MaxX=MinX+SatVibMap.AbsoluteSize.X
local MouseX,

MinY=math.clamp(Mouse.X,MinX,MaxX),SatVibMap.AbsolutePosition.Y
local MaxY=MinY+SatVibMap.AbsoluteSize.Y
local MouseY=math.clamp(Mouse.Y,MinY,MaxY)

ColorPicker.Sat=(MouseX-MinX)/(MaxX-MinX)
ColorPicker.Vib=1-((MouseY-MinY)/(MaxY-MinY))
ColorPicker:Display()

RenderStepped:Wait()
end

Library:AttemptSave()
end
end)

HueSelectorInner.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 then
while Library.Alive and InputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)do
local MinY=HueSelectorInner.AbsolutePosition.Y
local MaxY=MinY+HueSelectorInner.AbsoluteSize.Y
local MouseY=math.clamp(Mouse.Y,MinY,MaxY)

ColorPicker.Hue=((MouseY-MinY)/(MaxY-MinY))
ColorPicker:Display()

RenderStepped:Wait()
end

Library:AttemptSave()
end
end)

DisplayFrame.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 and not Library:MouseIsOverOpenedFrame()then
if PickerFrameOuter.Visible then
ColorPicker:Hide()
else
ContextMenu:Hide()
ColorPicker:Show()
end
elseif Input.UserInputType==Enum.UserInputType.MouseButton2 and not Library:MouseIsOverOpenedFrame()then
ContextMenu:Show()
ColorPicker:Hide()
end
end)

if TransparencyBoxInner then
TransparencyBoxInner.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 then
while Library.Alive and InputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)do
local MinX=TransparencyBoxInner.AbsolutePosition.X
local MaxX=MinX+TransparencyBoxInner.AbsoluteSize.X
local MouseX=math.clamp(Mouse.X,MinX,MaxX)

ColorPicker.Transparency=1-((MouseX-MinX)/(MaxX-MinX))

ColorPicker:Display()

RenderStepped:Wait()
end

Library:AttemptSave()
end
end)
end

Library:GiveSignal(InputService.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 then
local AbsPos,AbsSize=PickerFrameOuter.AbsolutePosition,PickerFrameOuter.AbsoluteSize

if
Mouse.X<AbsPos.X
or Mouse.X>AbsPos.X+AbsSize.X
or Mouse.Y<(AbsPos.Y-20-1)
or Mouse.Y>AbsPos.Y+AbsSize.Y
then
ColorPicker:Hide()
end

if not Library:IsMouseOverFrame(ContextMenu.Container)then
ContextMenu:Hide()
end
end

if Input.UserInputType==Enum.UserInputType.MouseButton2 and ContextMenu.Container.Visible then
if
not Library:IsMouseOverFrame(ContextMenu.Container)and not Library:IsMouseOverFrame(DisplayFrame)
then
ContextMenu:Hide()
end
end
end))

ColorPicker:Display()
ColorPicker.DisplayFrame=DisplayFrame

ColorPicker.FocusObject=DisplayFrame
Navigation.Register(Idx,ColorPicker,Info,self)
Options[Idx]=ColorPicker

return self
end

function Funcs.AddKeyPicker(self,Idx,Info)local
ParentObj, 
ToggleLabel, 
Container=self, self.TextLabel, self.Container

assert(Info.Default,"AddKeyPicker: Missing default value.")

local KeyPicker={
Value=Info.Default,
Toggled=false,
Mode=Info.Mode or"Toggle",
Type="KeyPicker",
Callback=Info.Callback or function(Value)end,
ChangedCallback=Info.ChangedCallback or function(New)end,

SyncToggleState=Info.SyncToggleState or false,
NoUI=Info.NoUI==true,
}

if KeyPicker.SyncToggleState then
Info.Modes={"Toggle"}
Info.Mode="Toggle"
end

local PickOuter=Library:Create("Frame",{
BackgroundColor3=Color3.new(0,0,0),
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(0,28,0,15),
ZIndex=6,
Parent=ToggleLabel,
})

local PickInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=7,
Parent=PickOuter,
})

Library:AddToRegistry(PickInner,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

local DisplayLabel,








ModeSelectOuter=Library:CreateLabel{Size=UDim2.new(1,0,1,0),TextSize=12,Text=Info.Default,TextWrapped=true,ZIndex=8,Parent=PickInner,},Library:Create("Frame",{
BorderColor3=Color3.new(0,0,0),
Position=UDim2.fromOffset(
ToggleLabel.AbsolutePosition.X+ToggleLabel.AbsoluteSize.X+4,
ToggleLabel.AbsolutePosition.Y+1
),
Size=UDim2.new(0,60,0,47),
Visible=false,
ZIndex=14,
Parent=ScreenGui,
})

ToggleLabel:GetPropertyChangedSignal"AbsolutePosition":Connect(function()
ModeSelectOuter.Position=UDim2.fromOffset(
ToggleLabel.AbsolutePosition.X+ToggleLabel.AbsoluteSize.X+4,
ToggleLabel.AbsolutePosition.Y+1
)
end)

local ModeSelectInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=15,
Parent=ModeSelectOuter,
})

Library:AddToRegistry(ModeSelectInner,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

Library:Create("UIListLayout",{
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=ModeSelectInner,
})

local ContainerLabel,








Modes,
ModeButtons=Library:CreateLabel({TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,18),TextSize=12,Visible=false,ZIndex=110,Parent=Library.KeybindContainer,},true),Info.Modes or{"Always","Toggle","Hold"},{}

for Idx,Mode in next,Modes do
local ModeButton,

Label={},Library:CreateLabel{
Active=false,
Size=UDim2.new(1,0,0,15),
TextSize=12,
Text=Mode,
ZIndex=16,
Parent=ModeSelectInner,
}

function ModeButton.Select(self)
for _,Button in next,ModeButtons do
Button:Deselect()
end

KeyPicker.Mode=Mode

Label.TextColor3=Library.AccentColor
Library.RegistryMap[Label].Properties.TextColor3="AccentColor"

ModeSelectOuter.Visible=false
end

function ModeButton.Deselect(self)
KeyPicker.Mode=nil

Label.TextColor3=Library.FontColor
Library.RegistryMap[Label].Properties.TextColor3="FontColor"
end

Label.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 then
ModeButton:Select()
Library:AttemptSave()
end
end)

if Mode==KeyPicker.Mode then
ModeButton:Select()
end

ModeButtons[Mode]=ModeButton
end

function KeyPicker.Update(self)
local State=KeyPicker:GetState()

ContainerLabel.Text=string.format("[%s] %s (%s)",KeyPicker.Value,Info.Text,KeyPicker.Mode)

ContainerLabel.Visible=not KeyPicker.NoUI
ContainerLabel.TextColor3=State and Library.AccentColor or Library.FontColor

Library.RegistryMap[ContainerLabel].Properties.TextColor3=State and"AccentColor"or"FontColor"

local YSize,
XSize=0,0

for _,Label in next,Library.KeybindContainer:GetChildren()do
if Label:IsA"TextLabel"and Label.Visible then
YSize=YSize+18
if Label.TextBounds.X>XSize then
XSize=Label.TextBounds.X
end
end
end

Library.KeybindFrame.Size=UDim2.new(0,math.max(XSize+10,210),0,YSize+25)
end

function KeyPicker.GetState(self)
if KeyPicker.Mode=="Always"then
return true
elseif KeyPicker.Mode=="Hold"then
if KeyPicker.Value=="-"or KeyPicker.Value==""then
return false
end

if InputService:GetFocusedTextBox()then return false end
local Key=KeyPicker.Value

if Key=="MB1"or Key=="MB2"then
return Key=="MB1"and InputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
or Key=="MB2"and InputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
else
local key=Library:ResolveKey(KeyPicker.Value)
return key~=nil and InputService:IsKeyDown(key)
end
else
return KeyPicker.Toggled
end
end

function KeyPicker.SetValue(self,Data)
assert(type(Data)=="table","binding must be a table")
local Key,Mode=Data[1],Data[2]
assert(type(Key)=="string"and ModeButtons[Mode],"invalid key binding")
assert(Key=="-"or Key==""or Key=="MB1"or Key=="MB2"or Library:ResolveKey(Key),"unknown key")
KeyPicker.Value=Key==""and"-"or Key
if KeyPicker.Value=="-"then KeyPicker.Toggled=false end
DisplayLabel.Text=KeyPicker.Value
ModeButtons[Mode]:Select()
local input=Library:ResolveKey(KeyPicker.Value)
Library:SafeCallback(KeyPicker.ChangedCallback,input)
Library:SafeCallback(KeyPicker.Changed,input)
KeyPicker:Update()
end

function KeyPicker.SetNoUI(self,Bool)
KeyPicker.NoUI=Bool

if Bool then
if ContainerLabel then
ContainerLabel.Visible=false
end

if ModeSelectOuter then
ModeSelectOuter.Visible=false
end

if PickOuter then
PickOuter.Active=false
end

KeyPicker:Update()
else
if ContainerLabel then
ContainerLabel.Visible=true
end

if PickOuter then
PickOuter.Active=true
end

KeyPicker:Update()
end
end

function KeyPicker.OnClick(self,Callback)
KeyPicker.Clicked=Callback
end

function KeyPicker.OnChanged(self,Callback)
KeyPicker.Changed=Callback
Callback(KeyPicker.Value)
end

if ParentObj.Addons then
table.insert(ParentObj.Addons,KeyPicker)
end

function KeyPicker.DoClick(self)
if ParentObj.Type=="Toggle"and KeyPicker.SyncToggleState then
ParentObj:SetValue(not ParentObj.Value)
end

Library:SafeCallback(KeyPicker.Callback,KeyPicker.Toggled)
Library:SafeCallback(KeyPicker.Clicked,KeyPicker.Toggled)
end

local Picking=false

PickOuter.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 and not Library:MouseIsOverOpenedFrame()then
if Library.CapturingInput then return end
Picking=true
Library.CapturingInput=true

DisplayLabel.Text=""

local
deadline,
Text,Break=os.clock()+10,""

task.spawn(function()
while Library.Alive and PickOuter.Parent and not Break do
if Text=="..."then
Text=""
end

Text=Text.."."
DisplayLabel.Text=tostring(math.max(0,math.ceil(deadline-os.clock()))).."s / Esc"

wait(0.4)
end
end)

wait(0.2)

local Event
Event=InputService.InputBegan:Connect(function(Input)
if not Library.Alive then return end
local Key

if Input.UserInputType==Enum.UserInputType.Keyboard then
Key=(Input.KeyCode.Name~="Backspace")and Input.KeyCode.Name or"-"
elseif Input.UserInputType==Enum.UserInputType.MouseButton1 then
Key="MB1"
elseif Input.UserInputType==Enum.UserInputType.MouseButton2 then
Key="MB2"
end

if Input.KeyCode==Enum.KeyCode.Escape then
Break=true Picking=false Library.CapturingInput=false
DisplayLabel.Text=KeyPicker.Value
Event:Disconnect()
return
end
if not Key then return end
Break=true
Picking=false
Library.CapturingInput=false

DisplayLabel.Text=Key
KeyPicker.Value=Key

local changedInput=Library:ResolveKey(Key)
Library:SafeCallback(KeyPicker.ChangedCallback,changedInput)
Library:SafeCallback(KeyPicker.Changed,changedInput)

Library:AttemptSave()

Event:Disconnect()
end)
Library:GiveSignal(Event)
task.delay(10,function()
if Picking then
Break=true
Picking=false
Library.CapturingInput=false
Event:Disconnect()
if Library.Alive then DisplayLabel.Text=KeyPicker.Value end
end
end)
elseif Input.UserInputType==Enum.UserInputType.MouseButton2 and not Library:MouseIsOverOpenedFrame()then
ModeSelectOuter.Visible=true
end
end)

Library:GiveSignal(InputService.InputBegan:Connect(function(Input,Processed)
if not Library.Alive or Processed or InputService:GetFocusedTextBox()or Library:IsNavigationKey(Input)then return end
if not Picking then
if KeyPicker.Mode=="Toggle"then
local Key=KeyPicker.Value

if Key=="MB1"or Key=="MB2"then
if
Key=="MB1"and Input.UserInputType==Enum.UserInputType.MouseButton1
or Key=="MB2"and Input.UserInputType==Enum.UserInputType.MouseButton2
then
KeyPicker.Toggled=not KeyPicker.Toggled
KeyPicker:DoClick()
end
elseif Input.UserInputType==Enum.UserInputType.Keyboard then
if Input.KeyCode.Name==Key then
KeyPicker.Toggled=not KeyPicker.Toggled
KeyPicker:DoClick()
end
end
end

KeyPicker:Update()
end

if Input.UserInputType==Enum.UserInputType.MouseButton1 then
local AbsPos,AbsSize=ModeSelectOuter.AbsolutePosition,ModeSelectOuter.AbsoluteSize

if
Mouse.X<AbsPos.X
or Mouse.X>AbsPos.X+AbsSize.X
or Mouse.Y<(AbsPos.Y-20-1)
or Mouse.Y>AbsPos.Y+AbsSize.Y
then
ModeSelectOuter.Visible=false
end
end
end))

Library:GiveSignal(InputService.InputEnded:Connect(function(Input)
if not Picking then
KeyPicker:Update()
end
end))

KeyPicker.FocusObject=PickOuter
Navigation.Register(Idx,KeyPicker,Info,ParentObj)
Options[Idx]=KeyPicker

return self
end

BaseAddons.__index=Funcs
BaseAddons.__namecall=function(Table,Key,...)
return Funcs[Key](...)
end
end

local BaseGroupbox={}

do
local Funcs={}

function Funcs.AddBlank(self,Size)
local Groupbox=self
local Container=Groupbox.Container

Library:Create("Frame",{
BackgroundTransparency=1,
Size=UDim2.new(1,0,0,Size),
ZIndex=1,
Parent=Container,
})
end

function Funcs.AddLabel(self,Text,DoesWrap)
local Label,

Groupbox={},self
local Container=Groupbox.Container

local TextLabel=Library:CreateLabel{
Size=UDim2.new(1,-4,0,15),
TextSize=12,
Text=Text,
TextWrapped=DoesWrap or false,
TextXAlignment=Enum.TextXAlignment.Left,
ZIndex=5,
Parent=Container,
}

if DoesWrap then
local Y=select(
2,
Library:GetTextBounds(Text,Library.FontFace,12,Vector2.new(TextLabel.AbsoluteSize.X,math.huge))
)
TextLabel.Size=UDim2.new(1,-4,0,Y)
else
Library:Create("UIListLayout",{
Padding=UDim.new(0,4),
FillDirection=Enum.FillDirection.Horizontal,
HorizontalAlignment=Enum.HorizontalAlignment.Right,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=TextLabel,
})
end

Label.TextLabel=TextLabel
Label.Container=Container

function Label.SetText(self,Text)
TextLabel.Text=Text

if DoesWrap then
local Y=select(
2,
Library:GetTextBounds(Text,Library.FontFace,12,Vector2.new(TextLabel.AbsoluteSize.X,math.huge))
)
TextLabel.Size=UDim2.new(1,-4,0,Y)
end

Groupbox:Resize()
end

if not DoesWrap then
setmetatable(Label,BaseAddons)
end

Groupbox:AddBlank(5)
Groupbox:Resize()

return Label
end

function Funcs.AddButton(self,...)

local Button,ProcessButtonParams={},function(
Class, Obj, ...)
local Props=select(1,...)
if type(Props)=="table"then
Obj.Text=Props.Text
Obj.Func=Props.Func
Obj.DoubleClick=Props.DoubleClick
Obj.Tooltip=Props.Tooltip
else
Obj.Text=select(1,...)
Obj.Func=select(2,...)
end

assert(type(Obj.Func)=="function","AddButton: `Func` callback is missing.")end


ProcessButtonParams("Button",Button,...)

local Groupbox=self
local Container,CreateBaseButton,InitEvents=Groupbox.Container,function(

Button)
local Outer=Library:Create("Frame",{
BackgroundColor3=Color3.new(0,0,0),
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(1,-4,0,20),
ZIndex=5,
})

local Inner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=6,
Parent=Outer,
})local

Gradient, 








Label=Library:Create("UIGradient",{Rotation=90,Parent=Inner,Color=ColorSequence.new{ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),ColorSequenceKeypoint.new(1,Color3.fromRGB(245,245,245)),},}), Library:CreateLabel{
Size=UDim2.new(1,0,1,0),
TextSize=12,
Text=Button.Text,
ZIndex=6,
Parent=Inner,
}

Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(212,212,212)),
},
Rotation=90,
Parent=Inner,
})

Library:AddToRegistry(Outer,{
BorderColor3="Black",
})

Library:AddToRegistry(Inner,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

Library:OnHighlight(Outer,Outer,{BorderColor3="AccentColor"},{BorderColor3="Black"})

return Outer,Inner,Label end,function(


Button)local WaitForEvent, ValidateClick=function(
event, timeout, validator)
local bindable,
completed=Instance.new"BindableEvent",false
local connection=event:Once(function(...)
if completed then return end
completed=true
if type(validator)=="function"and validator(...)then
bindable:Fire(true)
else
bindable:Fire(false)
end
end)
task.delay(timeout,function()
if completed then return end
completed=true
connection:Disconnect()
bindable:Fire(false)
end)
local result=bindable.Event:Wait()
bindable:Destroy()
return result end, function(


Input)
if Library:MouseIsOverOpenedFrame()then
return false
end

if Input.UserInputType~=Enum.UserInputType.MouseButton1 then
return false
end

return true end


Button.Outer.InputBegan:Connect(function(Input)
if not ValidateClick(Input)then
return
end
if Button.Locked then
return
end

if Button.DoubleClick then
Library:RemoveFromRegistry(Button.Label)
Library:AddToRegistry(Button.Label,{TextColor3="AccentColor"})

Button.Label.TextColor3=Library.AccentColor
Button.Label.Text="Are you sure?"
Button.Locked=true

local clicked=WaitForEvent(Button.Outer.InputBegan,0.5,ValidateClick)

Library:RemoveFromRegistry(Button.Label)
Library:AddToRegistry(Button.Label,{TextColor3="FontColor"})

Button.Label.TextColor3=Library.FontColor
Button.Label.Text=Button.Text
task.defer(rawset,Button,"Locked",false)

if clicked then
Library:SafeCallback(Button.Func)
end

return
end

Library:SafeCallback(Button.Func)
end)end


Button.Outer,Button.Inner,Button.Label=CreateBaseButton(Button)
Button.Outer.Parent=Container

InitEvents(Button)

function Button.AddTooltip(self,tooltip)
if type(tooltip)=="string"then
Library:AddToolTip(tooltip,self.Outer)
end
return self
end

function Button.AddButton(self,...)
local SubButton={}

ProcessButtonParams("SubButton",SubButton,...)

self.Outer.Size=UDim2.new(0.5,-2,0,20)

SubButton.Outer,SubButton.Inner,SubButton.Label=CreateBaseButton(SubButton)

SubButton.Outer.Position=UDim2.new(1,3,0,0)
SubButton.Outer.Size=UDim2.fromOffset(self.Outer.AbsoluteSize.X-2,self.Outer.AbsoluteSize.Y)
SubButton.Outer.Parent=self.Outer

function SubButton.AddTooltip(self,tooltip)
if type(tooltip)=="string"then
Library:AddToolTip(tooltip,self.Outer)
end
return SubButton
end

if type(SubButton.Tooltip)=="string"then
SubButton:AddTooltip(SubButton.Tooltip)
end

InitEvents(SubButton)
return SubButton
end

if type(Button.Tooltip)=="string"then
Button:AddTooltip(Button.Tooltip)
end

Groupbox:AddBlank(5)
Groupbox:Resize()

return Button
end

function Funcs.AddDivider(self)local
Groupbox, 
Container=self, self.Container





Groupbox:AddBlank(2)
local DividerOuter=Library:Create("Frame",{
BackgroundColor3=Color3.new(0,0,0),
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(1,-4,0,5),
ZIndex=5,
Parent=Container,
})

local DividerInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=6,
Parent=DividerOuter,
})

Library:AddToRegistry(DividerOuter,{
BorderColor3="Black",
})

Library:AddToRegistry(DividerInner,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

Groupbox:AddBlank(9)
Groupbox:Resize()
end

function Funcs.AddInput(self,Idx,Info)
assert(Info.Text,"AddInput: Missing `Text` string.")

local Textbox,







Groupbox={Value=Info.Default or"",Numeric=Info.Numeric or false,Finished=Info.Finished or false,Type="Input",Callback=Info.Callback or function(Value)end,},self
local Container=Groupbox.Container

Library:CreateLabel{
Size=UDim2.new(1,0,0,15),
TextSize=12,
Text=Info.Text,
TextXAlignment=Enum.TextXAlignment.Left,
ZIndex=5,
Parent=Container,
}

Groupbox:AddBlank(1)

local TextBoxOuter=Library:Create("Frame",{
BackgroundColor3=Color3.new(0,0,0),
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(1,-4,0,20),
ZIndex=5,
Parent=Container,
})

local TextBoxInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=6,
Parent=TextBoxOuter,
})

Library:AddToRegistry(TextBoxInner,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

Library:OnHighlight(TextBoxOuter,TextBoxOuter,{BorderColor3="AccentColor"},{BorderColor3="Black"})

if type(Info.Tooltip)=="string"then
Library:AddToolTip(Info.Tooltip,TextBoxOuter)
end

Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(212,212,212)),
},
Rotation=90,
Parent=TextBoxInner,
})

local Container=Library:Create("Frame",{
BackgroundTransparency=1,
ClipsDescendants=true,

Position=UDim2.new(0,5,0,0),
Size=UDim2.new(1,-5,1,0),

ZIndex=7,
Parent=TextBoxInner,
})

local Box=Library:Create("TextBox",{
BackgroundTransparency=1,

Position=UDim2.fromOffset(0,0),
Size=UDim2.fromScale(5,1),

PlaceholderColor3=Color3.fromRGB(190,190,190),
PlaceholderText=Info.Placeholder or"",

Text=Info.Default or"",
TextColor3=Library.FontColor,
TextSize=12,
TextStrokeTransparency=0,
TextXAlignment=Enum.TextXAlignment.Left,

ZIndex=7,
Parent=Container,

FontFace=Library.FontFace,
})

Library:ApplyTextStroke(Box)

function Textbox.SetValue(self,Text)
if Info.MaxLength and#Text>Info.MaxLength then
Text=Text:sub(1,Info.MaxLength)
end

if Textbox.Numeric then
if(not tonumber(Text))and Text:len()>0 then
Text=Textbox.Value
end
end

Textbox.Value=Text
Box.Text=Text

Library:SafeCallback(Textbox.Callback,Textbox.Value)
Library:SafeCallback(Textbox.Changed,Textbox.Value)
end

if Textbox.Finished then
Box.FocusLost:Connect(function(enter)
if not enter then
return
end

Textbox:SetValue(Box.Text)
Library:AttemptSave()
end)
else
Box:GetPropertyChangedSignal"Text":Connect(function()
Textbox:SetValue(Box.Text)
Library:AttemptSave()
end)
end local Update=function()





local PADDING,
reveal=2,Container.AbsoluteSize.X

if not Box:IsFocused()or Box.TextBounds.X<=reveal-2*PADDING then

Box.Position=UDim2.new(0,PADDING,0,0)
else

local cursor=Box.CursorPosition
if cursor~=-1 then

local subtext=string.sub(Box.Text,1,cursor-1)
local width=
TextService:GetTextSize(subtext,Box.TextSize,Box.Font,Vector2.new(math.huge,math.huge)).X


local currentCursorPos=Box.Position.X.Offset+width


if currentCursorPos<PADDING then
Box.Position=UDim2.fromOffset(PADDING-width,0)
elseif currentCursorPos>reveal-PADDING-1 then
Box.Position=UDim2.fromOffset(reveal-width-PADDING-1,0)
end
end
end end


task.spawn(Update)

Box:GetPropertyChangedSignal"Text":Connect(Update)
Box:GetPropertyChangedSignal"CursorPosition":Connect(Update)
Box.FocusLost:Connect(Update)
Box.Focused:Connect(Update)

Library:AddToRegistry(Box,{
TextColor3="FontColor",
})

function Textbox.OnChanged(self,Func)
Textbox.Changed=Func
Func(Textbox.Value)
end

Groupbox:AddBlank(5)
Groupbox:Resize()

Textbox.FocusObject=Box
Navigation.Register(Idx,Textbox,Info,Groupbox)
Options[Idx]=Textbox

return Textbox
end

function Funcs.AddToggle(self,Idx,Info)
assert(Info.Text,"AddInput: Missing `Text` string.")

local Toggle,








Groupbox={Value=Info.Default or false,Type="Toggle",Callback=Info.Callback or function(Value)end,Addons={},Risky=Info.Risky,},self
local Container=Groupbox.Container

local ToggleOuter=Library:Create("Frame",{
BackgroundColor3=Color3.new(0,0,0),
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(0,13,0,13),
ZIndex=5,
Parent=Container,
})

Library:AddToRegistry(ToggleOuter,{
BorderColor3="Black",
})

local ToggleInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=6,
Parent=ToggleOuter,
})

Library:Create("UIGradient",{
Rotation=90,
Parent=ToggleInner,
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(245,245,245)),
},
})

Library:AddToRegistry(ToggleInner,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

local ToggleLabel=Library:CreateLabel{
Size=UDim2.new(0,216,1,0),
Position=UDim2.new(1,6,0,0),
TextSize=12,
Text=Info.Text,
TextXAlignment=Enum.TextXAlignment.Left,
ZIndex=6,
Parent=ToggleInner,
}

Library:Create("UIListLayout",{
Padding=UDim.new(0,4),
FillDirection=Enum.FillDirection.Horizontal,
HorizontalAlignment=Enum.HorizontalAlignment.Right,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=ToggleLabel,
})

local ToggleRegion=Library:Create("Frame",{
BackgroundTransparency=1,
Size=UDim2.new(0,170,1,0),
ZIndex=8,
Parent=ToggleOuter,
})

Library:OnHighlight(ToggleRegion,ToggleOuter,{BorderColor3="AccentColor"},{BorderColor3="Black"})

function Toggle.UpdateColors(self)
Toggle:Display()
end

if type(Info.Tooltip)=="string"then
Library:AddToolTip(Info.Tooltip,ToggleRegion)
end

function Toggle.Display(self)
ToggleInner.BackgroundColor3=Toggle.Value and Library.AccentColor or Library.MainColor
ToggleInner.BorderColor3=Toggle.Value and Library.AccentColorDark or Library.OutlineColor

Library.RegistryMap[ToggleInner].Properties.BackgroundColor3=Toggle.Value and"AccentColor"or"MainColor"
Library.RegistryMap[ToggleInner].Properties.BorderColor3=Toggle.Value and"AccentColorDark"
or"OutlineColor"
end

function Toggle.OnChanged(self,Func)
Toggle.Changed=Func
Func(Toggle.Value)
end

function Toggle.SetValue(self,Bool)
Bool=not not Bool
if Bool and Toggle.Risky and not Library.AllowRiskyFeatures then Bool=false end
Toggle.Value=Bool
Toggle:Display()

for _,Addon in next,Toggle.Addons do
if Addon.Type=="KeyPicker"and Addon.SyncToggleState then
Addon.Toggled=Bool
Addon:Update()
end
end

Library:SafeCallback(Toggle.Callback,Toggle.Value)
Library:SafeCallback(Toggle.Changed,Toggle.Value)
Library:UpdateDependencyBoxes()
end

ToggleRegion.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 and not Library:MouseIsOverOpenedFrame()then
if not Toggle.Risky then
Toggle:SetValue(not Toggle.Value)
Library:AttemptSave()
else
if Library.AllowRiskyFeatures then
Toggle:SetValue(not Toggle.Value)
Library:AttemptSave()
end
end
end
end)

function Toggle.UpdateRiskyState(self)
if not Toggle.Risky then
return
end

Library:RemoveFromRegistry(ToggleLabel)

if Library.AllowRiskyFeatures then
ToggleLabel.TextColor3=Library.RiskColor
Library:AddToRegistry(ToggleLabel,{TextColor3="RiskColor"})
else
ToggleLabel.TextColor3=Library.DisabledColor or Library.TextColor
Library:AddToRegistry(ToggleLabel,{TextColor3="DisabledColor"})
if Toggle.Value then
Toggle:SetValue(false)
end
end

Toggle:Display()

end

if Toggle.Risky then
if Library.AllowRiskyFeatures then
Toggle:UpdateRiskyState()
else
Toggle:SetValue(false)
Toggle:UpdateRiskyState()
end
end

Toggle:Display()
Groupbox:AddBlank(Info.BlankSize or 7)
Groupbox:Resize()

Toggle.TextLabel=ToggleLabel
Toggle.Container=Container
setmetatable(Toggle,BaseAddons)

Toggle.FocusObject=ToggleRegion
Navigation.Register(Idx,Toggle,Info,Groupbox)
Toggles[Idx]=Toggle

Library:UpdateDependencyBoxes()

return Toggle
end

function Funcs.AddSlider(self,Idx,Info)
assert(Info.Default,"AddSlider: Missing default value.")
assert(Info.Text,"AddSlider: Missing slider text.")
assert(Info.Min,"AddSlider: Missing minimum value.")
assert(Info.Max,"AddSlider: Missing maximum value.")
assert(Info.Rounding,"AddSlider: Missing rounding value.")

local Slider,









Groupbox={Value=Info.Default,Min=Info.Min,Max=Info.Max,Rounding=Info.Rounding,MaxSize=232,Type="Slider",Callback=Info.Callback or function(Value)end,},self
local Container=Groupbox.Container

if not Info.Compact then
Library:CreateLabel{
Size=UDim2.new(1,0,0,10),
TextSize=12,
Text=Info.Text,
TextXAlignment=Enum.TextXAlignment.Left,
TextYAlignment=Enum.TextYAlignment.Bottom,
ZIndex=5,
Parent=Container,
}

Groupbox:AddBlank(3)
end

local SliderOuter=Library:Create("Frame",{
BackgroundColor3=Color3.new(0,0,0),
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(1,-4,0,13),
ZIndex=5,
Parent=Container,
})

Library:AddToRegistry(SliderOuter,{
BorderColor3="Black",
})

local SliderInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=6,
Parent=SliderOuter,
})

Library:Create("UIGradient",{
Rotation=90,
Parent=SliderInner,
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(245,245,245)),
},
})

Library:AddToRegistry(SliderInner,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

local Fill=Library:Create("Frame",{
BackgroundColor3=Library.AccentColor,
BorderColor3=Library.AccentColorDark,
Size=UDim2.new(0,0,1,0),
ZIndex=7,
Parent=SliderInner,
})

Library:Create("UIGradient",{
Rotation=90,
Parent=Fill,
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(245,245,245)),
},
})

Library:AddToRegistry(Fill,{
BackgroundColor3="AccentColor",
BorderColor3="AccentColorDark",
})

local HideBorderRight=Library:Create("Frame",{
BackgroundColor3=Library.AccentColor,
BorderSizePixel=0,
Position=UDim2.new(1,0,0,0),
Size=UDim2.new(0,1,1,0),
ZIndex=8,
Parent=Fill,
})

Library:AddToRegistry(HideBorderRight,{
BackgroundColor3="AccentColor",
})

local DisplayLabel=Library:CreateLabel{
Size=UDim2.new(1,0,1,0),
TextSize=12,
Text="Infinite",
ZIndex=9,
Parent=SliderInner,
}

Library:OnHighlight(SliderOuter,SliderOuter,{BorderColor3="AccentColor"},{BorderColor3="Black"})

if type(Info.Tooltip)=="string"then
Library:AddToolTip(Info.Tooltip,SliderOuter)
end

function Slider.UpdateColors(self)
Fill.BackgroundColor3=Library.AccentColor
Fill.BorderColor3=Library.AccentColorDark
end

function Slider.Display(self)
local Suffix=Info.Suffix or""

if Info.Compact then
DisplayLabel.Text=Info.Text..": "..Slider.Value..Suffix
elseif Info.HideMax then
DisplayLabel.Text=string.format("%s",Slider.Value..Suffix)
else
DisplayLabel.Text=string.format("%s/%s",Slider.Value..Suffix,Slider.Max..Suffix)
end

Slider.MaxSize=math.max(1,SliderInner.AbsoluteSize.X)
local X=math.ceil(Library:MapValue(Slider.Value,Slider.Min,Slider.Max,0,Slider.MaxSize))
Fill.Size=UDim2.new(0,X,1,0)

HideBorderRight.Visible=not(X==Slider.MaxSize or X==0)
end

function Slider.OnChanged(self,Func)
Slider.Changed=Func
Func(Slider.Value)
end local Round=function(

Value)
if Slider.Rounding==0 then
return math.floor(Value)
end

return tonumber(string.format("%."..Slider.Rounding.."f",Value))end


function Slider.GetValueFromXOffset(self,X)
return Round(Library:MapValue(X,0,Slider.MaxSize,Slider.Min,Slider.Max))
end

function Slider.SetValue(self,Str)
local Num=tonumber(Str)

if not Num or Num~=Num or math.abs(Num)==math.huge then
return
end

Num=math.clamp(Num,Slider.Min,Slider.Max)

Slider.Value=Num
Slider:Display()

Library:SafeCallback(Slider.Callback,Slider.Value)
Library:SafeCallback(Slider.Changed,Slider.Value)
end

function Slider.SetProperty(self,Property,Value)
assert(Property=="Min"or Property=="Max"or Property=="Rounding","unsupported slider property")
assert(type(Value)=="number"and Value==Value and math.abs(Value)<math.huge,"invalid slider property")
if Property=="Min"then assert(Value<Slider.Max,"minimum must be below maximum")end
if Property=="Max"then assert(Value>Slider.Min,"maximum must exceed minimum")end
Slider[Property]=Value
Slider:SetValue(Slider.Value)
end

SliderInner.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 and not Library:MouseIsOverOpenedFrame()then
local mPos,
gPos=Mouse.X,Fill.Size.X.Offset
local Diff=mPos-(Fill.AbsolutePosition.X+gPos)

while Library.Alive and InputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)do
local nMPos=Mouse.X
local nX=math.clamp(gPos+(nMPos-mPos)+Diff,0,Slider.MaxSize)

local nValue,
OldValue=Slider:GetValueFromXOffset(nX),Slider.Value
Slider.Value=nValue

Slider:Display()

if nValue~=OldValue then
Library:SafeCallback(Slider.Callback,Slider.Value)
Library:SafeCallback(Slider.Changed,Slider.Value)
end

RenderStepped:Wait()
end

Library:AttemptSave()
end
end)

Slider:Display()
Groupbox:AddBlank(Info.BlankSize or 6)
Groupbox:Resize()

Slider.FocusObject=SliderInner
Navigation.Register(Idx,Slider,Info,Groupbox)
Options[Idx]=Slider

return Slider
end

function Funcs.AddDropdown(self,Idx,Info)
if Info.SpecialType=="Player"then
Info.Values=GetPlayersString()
Info.AllowNull=true
elseif Info.SpecialType=="Team"then
Info.Values=GetTeamsString()
Info.AllowNull=true
end

assert(Info.Values,"AddDropdown: Missing dropdown value list.")
assert(
Info.AllowNull or Info.Default,
"AddDropdown: Missing default value. Pass `AllowNull` as true if this was intentional."
)

if not Info.Text then
Info.Compact=true
end

local Dropdown,








Groupbox={Values=Info.Values,Value=Info.Multi and{},Multi=Info.Multi,Type="Dropdown",SpecialType=Info.SpecialType,Callback=Info.Callback or function(Value)end,},self
local Container,

RelativeOffset=Groupbox.Container,0

if not Info.Compact then
Library:CreateLabel{
Size=UDim2.new(1,0,0,10),
TextSize=12,
Text=Info.Text,
TextXAlignment=Enum.TextXAlignment.Left,
TextYAlignment=Enum.TextYAlignment.Bottom,
ZIndex=5,
Parent=Container,
}

Groupbox:AddBlank(3)
end

for _,Element in next,Container:GetChildren()do
if not Element:IsA"UIListLayout"then
RelativeOffset=RelativeOffset+Element.Size.Y.Offset
end
end

local DropdownOuter=Library:Create("Frame",{
BackgroundColor3=Color3.new(0,0,0),
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(1,-4,0,20),
ZIndex=5,
Parent=Container,
})

Library:AddToRegistry(DropdownOuter,{
BorderColor3="Black",
})

local DropdownInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=6,
Parent=DropdownOuter,
})

Library:Create("UIGradient",{
Rotation=90,
Parent=DropdownInner,
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(245,245,245)),
},
})

Library:AddToRegistry(DropdownInner,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(212,212,212)),
},
Rotation=90,
Parent=DropdownInner,
})

local DropdownArrow,









ItemList=Library:Create("ImageLabel",{AnchorPoint=Vector2.new(0,0.5),BackgroundTransparency=1,Position=UDim2.new(1,-16,0.5,0),Size=UDim2.new(0,12,0,12),Image="http://www.roblox.com/asset/?id=6282522798",ZIndex=8,Parent=DropdownInner,}),Library:CreateLabel{
Position=UDim2.new(0,5,0,0),
Size=UDim2.new(1,-5,1,0),
TextSize=12,
Text="--",
TextXAlignment=Enum.TextXAlignment.Left,
TextWrapped=true,
ZIndex=7,
Parent=DropdownInner,
}

Library:OnHighlight(DropdownOuter,DropdownOuter,{BorderColor3="AccentColor"},{BorderColor3="Black"})

if type(Info.Tooltip)=="string"then
Library:AddToolTip(Info.Tooltip,DropdownOuter)
end

local MAX_DROPDOWN_ITEMS,

ListOuter=8,Library:Create("Frame",{
BackgroundColor3=Color3.new(0,0,0),
BorderColor3=Color3.new(0,0,0),
ZIndex=20,
Visible=false,
Parent=ScreenGui,
})local RecalculateListPosition, RecalculateListSize=function()


ListOuter.Position=UDim2.fromOffset(
DropdownOuter.AbsolutePosition.X,
DropdownOuter.AbsolutePosition.Y+DropdownOuter.Size.Y.Offset+1
)end, function(


YSize)
ListOuter.Size=UDim2.fromOffset(DropdownOuter.AbsoluteSize.X,YSize or(MAX_DROPDOWN_ITEMS*20+2))end


RecalculateListPosition()
RecalculateListSize()

DropdownOuter:GetPropertyChangedSignal"AbsolutePosition":Connect(RecalculateListPosition)

local ListInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
BorderSizePixel=0,
Size=UDim2.new(1,0,1,0),
ZIndex=21,
Parent=ListOuter,
})

Library:Create("UIGradient",{
Rotation=90,
Parent=ListInner,
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(245,245,245)),
},
})

Library:AddToRegistry(ListInner,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

local Scrolling=Library:Create("ScrollingFrame",{
BackgroundTransparency=1,
BorderSizePixel=0,
CanvasSize=UDim2.new(0,0,0,0),
Size=UDim2.new(1,0,1,0),
ZIndex=21,
Parent=ListInner,

TopImage="rbxasset://textures/ui/Scroll/scroll-middle.png",
BottomImage="rbxasset://textures/ui/Scroll/scroll-middle.png",

ScrollBarThickness=3,
ScrollBarImageColor3=Library.AccentColor,
})

Library:AddToRegistry(Scrolling,{
ScrollBarImageColor3="AccentColor",
})

Library:Create("UIListLayout",{
Padding=UDim.new(0,0),
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=Scrolling,
})

function Dropdown.Display(self)
local Values,
Str=Dropdown.Values,""

if Info.Multi then
for Idx,Value in next,Values do
if Dropdown.Value[Value]then
Str=Str..Value..", "
end
end

Str=Str:sub(1,#Str-2)
else
Str=Dropdown.Value or""
end

ItemList.Text=(Str==""and"--"or Str)
end

function Dropdown.GetActiveValues(self)
if Info.Multi then
local T={}

for Value,Bool in next,Dropdown.Value do
if Bool then table.insert(T,Value)end
end

return#T
else
return Dropdown.Value and 1 or 0
end
end

function Dropdown.BuildDropdownList(self)
local Values,
Buttons=Dropdown.Values,{}

for _,Element in next,Scrolling:GetChildren()do
if not Element:IsA"UIListLayout"then
Element:Destroy()
end
end

local Count=0

for Idx,Value in next,Values do
local Table={}

Count=Count+1

local Button=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Middle,
Size=UDim2.new(1,-1,0,20),
ZIndex=23,
Active=true,
Parent=Scrolling,
})

Library:AddToRegistry(Button,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

local ButtonLabel=Library:CreateLabel{
Active=false,
Size=UDim2.new(1,-6,1,0),
Position=UDim2.new(0,6,0,0),
TextSize=12,
Text=Value,
TextXAlignment=Enum.TextXAlignment.Left,
ZIndex=25,
Parent=Button,
}

Library:OnHighlight(
Button,
Button,
{BorderColor3="AccentColor",ZIndex=24},
{BorderColor3="OutlineColor",ZIndex=23}
)

local Selected

if Info.Multi then
Selected=Dropdown.Value[Value]
else
Selected=Dropdown.Value==Value
end

function Table.UpdateButton(self)
if Info.Multi then
Selected=Dropdown.Value[Value]
else
Selected=Dropdown.Value==Value
end

ButtonLabel.TextColor3=Selected and Library.AccentColor or Library.FontColor
Library.RegistryMap[ButtonLabel].Properties.TextColor3=Selected and"AccentColor"or"FontColor"
end

ButtonLabel.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 then
local Try=not Selected

if Dropdown:GetActiveValues()==1 and not Try and not Info.AllowNull then
else
if Info.Multi then
Selected=Try

if Selected then
Dropdown.Value[Value]=true
else
Dropdown.Value[Value]=nil
end
else
Selected=Try

if Selected then
Dropdown.Value=Value
else
Dropdown.Value=nil
end

for _,OtherButton in next,Buttons do
OtherButton:UpdateButton()
end
end

Table:UpdateButton()
Dropdown:Display()

Library:SafeCallback(Dropdown.Callback,Dropdown.Value)
Library:SafeCallback(Dropdown.Changed,Dropdown.Value)

Library:AttemptSave()
end
end
end)

Table:UpdateButton()
Dropdown:Display()

Buttons[Button]=Table
end

Scrolling.CanvasSize=UDim2.fromOffset(0,(Count*20)+1)

local Y=math.clamp(Count*20,0,MAX_DROPDOWN_ITEMS*20)+1
RecalculateListSize(Y)
end

function Dropdown.SetValues(self,NewValues)
if NewValues then
Dropdown.Values=NewValues
end

if Dropdown.Multi then
for value in Dropdown.Value do
if not table.find(Dropdown.Values,value)then Dropdown.Value[value]=nil end
end
elseif Dropdown.Value and not table.find(Dropdown.Values,Dropdown.Value)then
Dropdown.Value=nil
end
Dropdown:BuildDropdownList()
Library:SafeCallback(Dropdown.Callback,Dropdown.Value)
Library:SafeCallback(Dropdown.Changed,Dropdown.Value)
end

function Dropdown.OpenDropdown(self)
ListOuter.Visible=true
Library.OpenedFrames[ListOuter]=true
Library:ClampPopup(ListOuter)
DropdownArrow.Rotation=180
end

function Dropdown.CloseDropdown(self)
ListOuter.Visible=false
Library.OpenedFrames[ListOuter]=nil
DropdownArrow.Rotation=0
end

function Dropdown.OnChanged(self,Func)
Dropdown.Changed=Func
Func(Dropdown.Value)
end

function Dropdown.SetValue(self,Val)
if Dropdown.Multi then
local nTable={}

for Value,Bool in next,Val or{}do
if Bool and table.find(Dropdown.Values,Value)then
nTable[Value]=true
end
end

Dropdown.Value=nTable
else
if not Val then
Dropdown.Value=nil
elseif table.find(Dropdown.Values,Val)then
Dropdown.Value=Val
end
end

Dropdown:BuildDropdownList()

Library:SafeCallback(Dropdown.Callback,Dropdown.Value)
Library:SafeCallback(Dropdown.Changed,Dropdown.Value)
end

DropdownOuter.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 and not Library:MouseIsOverOpenedFrame()then
if ListOuter.Visible then
Dropdown:CloseDropdown()
else
Dropdown:OpenDropdown()
end
end
end)

Library:GiveSignal(InputService.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 then
local AbsPos,AbsSize=ListOuter.AbsolutePosition,ListOuter.AbsoluteSize

if
Mouse.X<AbsPos.X
or Mouse.X>AbsPos.X+AbsSize.X
or Mouse.Y<(AbsPos.Y-20-1)
or Mouse.Y>AbsPos.Y+AbsSize.Y
then
Dropdown:CloseDropdown()
end
end
end))

Dropdown:BuildDropdownList()
Dropdown:Display()

local Defaults={}

if type(Info.Default)=="string"then
local Idx=table.find(Dropdown.Values,Info.Default)
if Idx then
table.insert(Defaults,Idx)
end
elseif type(Info.Default)=="table"then
for _,Value in next,Info.Default do
local Idx=table.find(Dropdown.Values,Value)
if Idx then
table.insert(Defaults,Idx)
end
end
elseif type(Info.Default)=="number"and Dropdown.Values[Info.Default]~=nil then
table.insert(Defaults,Info.Default)
end

if next(Defaults)then
for i=1,#Defaults do
local Index=Defaults[i]
if Info.Multi then
Dropdown.Value[Dropdown.Values[Index] ]=true
else
Dropdown.Value=Dropdown.Values[Index]
end

if not Info.Multi then
break
end
end

Dropdown:BuildDropdownList()
Dropdown:Display()
end

Groupbox:AddBlank(Info.BlankSize or 5)
Groupbox:Resize()

Dropdown.FocusObject=DropdownOuter
Navigation.Register(Idx,Dropdown,Info,Groupbox)
Options[Idx]=Dropdown

return Dropdown
end

function Funcs.AddDependencyBox(self)
local Depbox,



Groupbox={Dependencies={},},self
local Container=Groupbox.Container

local Holder=Library:Create("Frame",{
BackgroundTransparency=1,
Size=UDim2.new(1,0,0,0),
Visible=false,
Parent=Container,
})

local Frame=Library:Create("Frame",{
BackgroundTransparency=1,
Size=UDim2.new(1,0,1,0),
Visible=true,
Parent=Holder,
})

local Layout=Library:Create("UIListLayout",{
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=Frame,
})

function Depbox.Resize(self)
Holder.Size=UDim2.new(1,0,0,Layout.AbsoluteContentSize.Y)
Groupbox:Resize()
end

Layout:GetPropertyChangedSignal"AbsoluteContentSize":Connect(function()
Depbox:Resize()
end)

Holder:GetPropertyChangedSignal"Visible":Connect(function()
Depbox:Resize()
end)

function Depbox.Update(self)
for _,Dependency in next,Depbox.Dependencies do
local Elem,
Value=Dependency[1],Dependency[2]

if Elem.Type=="Toggle"and Elem.Value~=Value then
Holder.Visible=false
Depbox:Resize()
return
end
end

Holder.Visible=true
Depbox:Resize()
end

function Depbox.SetupDependencies(self,Dependencies)
for _,Dependency in next,Dependencies do
assert(type(Dependency)=="table","SetupDependencies: Dependency is not of type `table`.")
assert(Dependency[1],"SetupDependencies: Dependency is missing element argument.")
assert(Dependency[2]~=nil,"SetupDependencies: Dependency is missing value argument.")
end

Depbox.Dependencies=Dependencies
Depbox:Update()
end

Depbox.Container=Frame

setmetatable(Depbox,BaseGroupbox)

table.insert(Library.DependencyBoxes,Depbox)

return Depbox
end

BaseGroupbox.__index=Funcs
BaseGroupbox.__namecall=function(Table,Key,...)
return Funcs[Key](...)
end
end


do
Library.NotificationArea=Library:Create("Frame",{
BackgroundTransparency=1,
Position=UDim2.new(0,0,0,40),
Size=UDim2.new(0,300,0,200),
ZIndex=100,
Parent=ScreenGui,
})

Library:Create("UIListLayout",{
Padding=UDim.new(0,4),
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=Library.NotificationArea,
})

local WatermarkOuter=Library:Create("Frame",{
BorderColor3=Color3.new(0,0,0),
Position=UDim2.new(0,250,0,-30),
Size=UDim2.new(0,230,0,20),
ZIndex=200,
Visible=false,
Parent=ScreenGui,
})

local WatermarkInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
Size=UDim2.new(1,0,1,0),
BorderSizePixel=0,
ZIndex=201,
Parent=WatermarkOuter,
})

local InnerFrame=Library:Create("Frame",{
BackgroundColor3=Color3.new(1,1,1),
BorderSizePixel=0,
Position=UDim2.new(0,1,0,1),
Size=UDim2.new(1,-2,1,-2),
ZIndex=202,
Parent=WatermarkInner,
})

local ColorLine=Library:Create("Frame",{
BackgroundColor3=Library.AccentColor,
BorderSizePixel=0,
Size=UDim2.new(1,0,0,1),
ZIndex=204,
Parent=InnerFrame,
})

Library:AddToRegistry(ColorLine,{
BackgroundColor3="AccentColor",
})

local Gradient=Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Library:GetDarkerColor(Library.MainColor)),
ColorSequenceKeypoint.new(1,Library.MainColor),
},
Rotation=90,
Parent=InnerFrame,
})

Library:AddToRegistry(Gradient,{
Color=function()
return ColorSequence.new{
ColorSequenceKeypoint.new(0,Library:GetDarkerColor(Library.MainColor)),
ColorSequenceKeypoint.new(1,Library.MainColor),
}
end,
})

local WatermarkLabel=Library:CreateLabel{
Position=UDim2.new(0,0,0,0),
Size=UDim2.new(1,0,1,0),
TextSize=12,
TextXAlignment=Enum.TextXAlignment.Center,
ZIndex=203,
Parent=InnerFrame,
AutomaticSize=Enum.AutomaticSize.X,
}

Library.Watermark=WatermarkOuter
Library.WatermarkText=WatermarkLabel
Library:MakeDraggable(Library.Watermark)

local KeybindOuter=Library:Create("Frame",{
BorderColor3=Color3.new(0,0,0),
Position=UDim2.new(0,10,0.5,0),
ZIndex=100,
Visible=false,
Parent=ScreenGui,
})

local KeybindInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
Size=UDim2.new(1,0,1,0),
BorderSizePixel=0,
ZIndex=101,
Parent=KeybindOuter,
})

local InnerFrame=Library:Create("Frame",{
BackgroundColor3=Color3.new(1,1,1),
BorderSizePixel=0,
Position=UDim2.new(0,1,0,1),
Size=UDim2.new(1,-2,1,-2),
BorderSizePixel=0,
ZIndex=102,
Parent=KeybindInner,
})

local ColorLine=Library:Create("Frame",{
BackgroundColor3=Library.AccentColor,
BorderSizePixel=0,
Size=UDim2.new(1,0,0,1),
ZIndex=104,
Parent=InnerFrame,
})

Library:AddToRegistry(ColorLine,{
BackgroundColor3="AccentColor",
})

local Gradient=Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Library:GetDarkerColor(Library.MainColor)),
ColorSequenceKeypoint.new(1,Library.MainColor),
},
Rotation=90,
Parent=InnerFrame,
})

Library:AddToRegistry(Gradient,{
Color=function()
return ColorSequence.new{
ColorSequenceKeypoint.new(0,Library:GetDarkerColor(Library.MainColor)),
ColorSequenceKeypoint.new(1,Library.MainColor),
}
end,
})local

KeybindLabel, 









KeybindContainer=Library:CreateLabel{Size=UDim2.new(1,0,0,20),Position=UDim2.fromOffset(5,1),TextXAlignment=Enum.TextXAlignment.Left,Text="Keybinds",ZIndex=104,Parent=KeybindInner,}, Library:Create("Frame",{
BackgroundTransparency=1,
Size=UDim2.new(1,0,1,-20),
Position=UDim2.new(0,0,0,20),
ZIndex=1,
Parent=KeybindInner,
})

Library:Create("UIListLayout",{
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=KeybindContainer,
})

Library:Create("UIPadding",{
PaddingLeft=UDim.new(0,5),
Parent=KeybindContainer,
})

Library.KeybindFrame=KeybindOuter
Library.KeybindContainer=KeybindContainer
Library:MakeDraggable(KeybindOuter)
end

function Library.SetWatermarkVisibility(self,Bool)
Library.Watermark.Visible=Bool
end

function Library.SetWatermark(self,Text)
local X,Y=Library:GetTextBounds(Text,Library.FontFace,12)
Library.Watermark.Size=UDim2.new(0,X+15,0,(Y*1.5)+3)
Library:SetWatermarkVisibility(true)

Library.WatermarkText.Text=Text
end

function Library.Notify(self,Text,Time)
if not Library.Alive then return end
Text=tostring(Text)
local XSize,YSize=Library:GetTextBounds(Text,Library.FontFace,12)

YSize=YSize+7

local NotifyOuter=Library:Create("Frame",{
BorderColor3=Color3.new(0,0,0),
Position=UDim2.new(0,100,0,10),
Size=UDim2.new(0,0,0,YSize),
ClipsDescendants=true,
ZIndex=100,
Parent=Library.NotificationArea,
})

local NotifyInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=101,
Parent=NotifyOuter,
})

Library:AddToRegistry(NotifyInner,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
},true)

local InnerFrame=Library:Create("Frame",{
BackgroundColor3=Color3.new(1,1,1),
BorderSizePixel=0,
Position=UDim2.new(0,1,0,1),
Size=UDim2.new(1,-2,1,-2),
ZIndex=102,
Parent=NotifyInner,
})

local Gradient=Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Library:GetDarkerColor(Library.MainColor)),
ColorSequenceKeypoint.new(1,Library.MainColor),
},
Rotation=90,
Parent=InnerFrame,
})

Library:AddToRegistry(Gradient,{
Color=function()
return ColorSequence.new{
ColorSequenceKeypoint.new(0,Library:GetDarkerColor(Library.MainColor)),
ColorSequenceKeypoint.new(1,Library.MainColor),
}
end,
})local

NotifyLabel, 









LeftColor=Library:CreateLabel{Position=UDim2.new(0,4,0,0),Size=UDim2.new(1,-4,1,0),Text=Text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12,ZIndex=103,Parent=InnerFrame,}, Library:Create("Frame",{
BackgroundColor3=Library.AccentColor,
BorderSizePixel=0,
Position=UDim2.new(0,-1,0,-1),
Size=UDim2.new(0,3,1,2),
ZIndex=104,
Parent=NotifyOuter,
})

Library:AddToRegistry(LeftColor,{
BackgroundColor3="AccentColor",
},true)

pcall(NotifyOuter.TweenSize,NotifyOuter,UDim2.new(0,XSize+8+4,0,YSize),"Out","Quad",0.4,true)

task.spawn(function()
wait(Time or 5)

pcall(NotifyOuter.TweenSize,NotifyOuter,UDim2.new(0,0,0,YSize),"Out","Quad",0.4,true)

wait(0.4)

NotifyOuter:Destroy()
end)
end

function Library.CreateWindow(self,...)
local Arguments,
Config={...},{AnchorPoint=Vector2.zero}

if type(...)=="table"then
Config=...
else
Config.Title=Arguments[1]
Config.AutoShow=Arguments[2]or false
end

if type(Config.Title)~="string"then
Config.Title="No title"
end
if type(Config.TabPadding)~="number"then
Config.TabPadding=0
end
if type(Config.MenuFadeTime)~="number"then
Config.MenuFadeTime=0.2
end

if typeof(Config.Position)~="UDim2"then
Config.Position=UDim2.fromOffset(175,50)
end
if typeof(Config.Size)~="UDim2"then
Config.Size=UDim2.fromOffset(760,640)
end

if Config.Center then
Config.AnchorPoint=Vector2.new(0.5,0.5)
Config.Position=UDim2.fromScale(0.5,0.5)
end

local Window={
Tabs={},
}
Library.Window=Window

local Outer=Library:Create("Frame",{
AnchorPoint=Config.AnchorPoint,
BackgroundColor3=Color3.new(0,0,0),
BorderSizePixel=0,
Position=Config.Position,
Size=Config.Size,
Visible=false,
ZIndex=1,
Parent=ScreenGui,
})

Library:MakeDraggable(Outer,42)
Library.ScaleControl=Library:Create("UIScale",{Scale=1,Parent=Outer})
Window.Outer=Outer

local Glow=Library:Create("ImageLabel",{
Parent=Outer,
ImageColor3=Library.AccentColor,
ScaleType=Enum.ScaleType.Slice,
BorderColor3=Color3.fromRGB(0,0,0),
BackgroundColor3=Color3.fromRGB(255,255,255),
Image="http://www.roblox.com/asset/?id=18245826428",
BackgroundTransparency=1,
ImageTransparency=0.94,
Position=UDim2.new(0,-20,0,-20),
Size=UDim2.new(1,40,1,40),
ZIndex=1,
BorderSizePixel=0,
SliceCenter=Rect.new(Vector2.new(21,21),Vector2.new(79,79)),
})

Library:AddToRegistry(Glow,{
ImageColor3="AccentColor",
})

local Inner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.AccentColor,
BorderMode=Enum.BorderMode.Inset,
Position=UDim2.new(0,1,0,1),
Size=UDim2.new(1,-2,1,-2),
ZIndex=1,
Parent=Outer,
})

Library:AddToRegistry(Inner,{
BackgroundColor3="MainColor",
BorderColor3="AccentColor",
})

local WindowLabel,









MainSectionOuter=Library:CreateLabel{Position=UDim2.new(0,16,0,0),TextSize=18,Size=UDim2.new(0,0,0,42),Text=Config.Title or"",TextXAlignment=Enum.TextXAlignment.Left,ZIndex=1,Parent=Inner,},Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
Position=UDim2.new(0,12,0,42),
Size=UDim2.new(1,-24,1,-54),
ZIndex=1,
Parent=Inner,
})

Library:AddToRegistry(MainSectionOuter,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

local MainSectionInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Color3.new(0,0,0),
BorderMode=Enum.BorderMode.Inset,
Position=UDim2.new(0,0,0,0),
Size=UDim2.new(1,0,1,0),
ZIndex=1,
Parent=MainSectionOuter,
})

Library:AddToRegistry(MainSectionInner,{
BackgroundColor3="BackgroundColor",
})

local TabArea=Library:Create("Frame",{
BackgroundTransparency=1,
Position=UDim2.new(0,8,0,8),
Size=UDim2.new(1,-16,0,30),
ZIndex=1,
Parent=MainSectionInner,
})

local TabListLayout,







TabContainer=Library:Create("UIListLayout",{Padding=UDim.new(0,Config.TabPadding),FillDirection=Enum.FillDirection.Horizontal,SortOrder=Enum.SortOrder.LayoutOrder,HorizontalFlex=Enum.UIFlexAlignment.Fill,Parent=TabArea,}),Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
Position=UDim2.new(0,8,0,44),
Size=UDim2.new(1,-16,1,-52),
ZIndex=2,
Parent=MainSectionInner,
})

Library:AddToRegistry(TabContainer,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

function Window.SetWindowTitle(self,Title)
WindowLabel.Text=Title
end

function Window.AddTab(self,Name)local
Tab, 





TabButtonWidth, 

TabButton={Name=Name,Groupboxes={},Tabboxes={},}, Library:GetTextBounds(Name,Library.FontFace,16), Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
Size=UDim2.new(0,12,1,0),
ZIndex=1,
Parent=TabArea,
})

Library:Create("UIGradient",{
Rotation=-90,
Parent=TabButton,
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(245,245,245)),
},
})

Library:AddToRegistry(TabButton,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})local

TabButtonLabel, 







Blocker=Library:CreateLabel{Position=UDim2.new(0,0,0,0),Size=UDim2.new(1,0,1,-1),Text=Name,ZIndex=1,Parent=TabButton,}, Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderSizePixel=0,
Position=UDim2.new(0,0,1,0),
Size=UDim2.new(1,0,0,1),
BackgroundTransparency=1,
ZIndex=3,
Parent=TabButton,
})

Library:AddToRegistry(Blocker,{
BackgroundColor3="MainColor",
})

local TabFrame=Library:Create("Frame",{
Name="TabFrame",
BackgroundTransparency=1,
Position=UDim2.new(0,0,0,0),
Size=UDim2.new(1,0,1,0),
Visible=false,
ZIndex=2,
Parent=TabContainer,
})local

Gradient, 








LeftSide, 












RightSide=Library:Create("UIGradient",{Rotation=-90,Parent=TabFrame,Color=ColorSequence.new{ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),ColorSequenceKeypoint.new(1,Color3.fromRGB(245,245,245)),},}), Library:Create("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,7,0,7),Size=UDim2.new(0.5,-10,1,-14),CanvasSize=UDim2.new(0,0,0,0),BottomImage="",TopImage="",ScrollBarThickness=0,ZIndex=2,Parent=TabFrame,}), Library:Create("ScrollingFrame",{
BackgroundTransparency=1,
BorderSizePixel=0,
Position=UDim2.new(0.5,5,0,7),
Size=UDim2.new(0.5,-10,1,-14),
CanvasSize=UDim2.new(0,0,0,0),
BottomImage="",
TopImage="",
ScrollBarThickness=0,
ZIndex=2,
Parent=TabFrame,
})

Library:Create("UIListLayout",{
Padding=UDim.new(0,8),
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
HorizontalAlignment=Enum.HorizontalAlignment.Center,
Parent=LeftSide,
})

Library:Create("UIListLayout",{
Padding=UDim.new(0,8),
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
HorizontalAlignment=Enum.HorizontalAlignment.Center,
Parent=RightSide,
})

for _,Side in next,{LeftSide,RightSide}do
Side:WaitForChild"UIListLayout":GetPropertyChangedSignal"AbsoluteContentSize":Connect(function()
Side.CanvasSize=UDim2.fromOffset(0,Side.UIListLayout.AbsoluteContentSize.Y)
end)
end

function Tab.ShowTab(self)
for _,Tab in next,Window.Tabs do
Tab:HideTab()
end

Blocker.BackgroundTransparency=0
TabButton.BackgroundColor3=Library.MainColor
Library.RegistryMap[TabButton].Properties.BackgroundColor3="MainColor"
TabFrame.Visible=true
end

function Tab.HideTab(self)
Library:ClosePopups()
Blocker.BackgroundTransparency=1
TabButton.BackgroundColor3=Library.BackgroundColor
Library.RegistryMap[TabButton].Properties.BackgroundColor3="BackgroundColor"
TabFrame.Visible=false
end

function Tab.SetLayoutOrder(self,Position)
TabButton.LayoutOrder=Position
TabListLayout:ApplyLayout()
end

function Tab.AddGroupbox(self,Info)
local Groupbox,

BoxOuter={Name=Info.Name,OwnerTab=Tab},Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,0,509),
ZIndex=2,
Parent=Info.Side==1 and LeftSide or RightSide,
})

Library:AddToRegistry(BoxOuter,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

local BoxInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Color3.new(0,0,0),

Size=UDim2.new(1,-2,1,-2),
Position=UDim2.new(0,1,0,1),
ZIndex=4,
Parent=BoxOuter,
})

Library:AddToRegistry(BoxInner,{
BackgroundColor3="BackgroundColor",
})

local Highlight=Library:Create("Frame",{
BackgroundColor3=Library.AccentColor,
BorderSizePixel=0,
Size=UDim2.new(1,0,0,2),
ZIndex=5,
Parent=BoxInner,
})

Library:AddToRegistry(Highlight,{
BackgroundColor3="AccentColor",
})local

GroupboxLabel, 









Container=Library:CreateLabel{Size=UDim2.new(1,0,0,18),Position=UDim2.new(0,4,0,2),TextSize=12,Text=Info.Name,TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,Parent=BoxInner,}, Library:Create("Frame",{
BackgroundTransparency=1,
Position=UDim2.new(0,4,0,20),
Size=UDim2.new(1,-4,1,-20),
ZIndex=1,
Parent=BoxInner,
})

Library:Create("UIListLayout",{
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=Container,
})

function Groupbox.Resize(self)
local Size=0

for _,Element in next,Groupbox.Container:GetChildren()do
if(not Element:IsA"UIListLayout")and Element.Visible then
Size=Size+Element.Size.Y.Offset
end
end

BoxOuter.Size=UDim2.new(1,0,0,20+Size+2+2)
end

Groupbox.Container=Container
setmetatable(Groupbox,BaseGroupbox)

Groupbox:AddBlank(3)
Groupbox:Resize()

Tab.Groupboxes[Info.Name]=Groupbox

return Groupbox
end

function Tab.AddLeftGroupbox(self,Name)
return Tab:AddGroupbox{Side=1,Name=Name}
end

function Tab.AddRightGroupbox(self,Name)
return Tab:AddGroupbox{Side=2,Name=Name}
end

function Tab.AddTabbox(self,Info)
local Tabbox,




BoxOuter={OwnerTab=Tab,Tabs={},},Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,0,0),
ZIndex=2,
Parent=Info.Side==1 and LeftSide or RightSide,
})

Library:AddToRegistry(BoxOuter,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

local BoxInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Color3.new(0,0,0),

Size=UDim2.new(1,-2,1,-2),
Position=UDim2.new(0,1,0,1),
ZIndex=4,
Parent=BoxOuter,
})

Library:AddToRegistry(BoxInner,{
BackgroundColor3="BackgroundColor",
})

local Highlight=Library:Create("Frame",{
BackgroundColor3=Library.AccentColor,
BorderSizePixel=0,
Size=UDim2.new(1,0,0,2),
ZIndex=10,
Parent=BoxInner,
})

Library:AddToRegistry(Highlight,{
BackgroundColor3="AccentColor",
})

local TabboxButtons=Library:Create("Frame",{
BackgroundTransparency=1,
Position=UDim2.new(0,0,0,1),
Size=UDim2.new(1,0,0,18),
ZIndex=5,
Parent=BoxInner,
})

Library:Create("UIListLayout",{
FillDirection=Enum.FillDirection.Horizontal,
HorizontalAlignment=Enum.HorizontalAlignment.Left,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=TabboxButtons,
})

function Tabbox.AddTab(self,Name)
local Tab,

Button={Name=Name,OwnerTab=Tabbox.OwnerTab},Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(0.5,0,1,0),
ZIndex=6,
Parent=TabboxButtons,
})

Library:AddToRegistry(Button,{
BackgroundColor3="MainColor",
})local

ButtonLabel, 








Block=Library:CreateLabel{Size=UDim2.new(1,0,1,0),TextSize=12,Text=Name,TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7,Parent=Button,}, Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderSizePixel=0,
Position=UDim2.new(0,0,1,0),
Size=UDim2.new(1,0,0,1),
Visible=false,
ZIndex=9,
Parent=Button,
})

Library:AddToRegistry(Block,{
BackgroundColor3="BackgroundColor",
})

local Container=Library:Create("Frame",{
BackgroundTransparency=1,
Position=UDim2.new(0,4,0,20),
Size=UDim2.new(1,-4,1,-20),
ZIndex=1,
Visible=false,
Parent=BoxInner,
})

Library:Create("UIListLayout",{
FillDirection=Enum.FillDirection.Vertical,
SortOrder=Enum.SortOrder.LayoutOrder,
Parent=Container,
})

function Tab.Show(self)
for _,Tab in next,Tabbox.Tabs do
Tab:Hide()
end

Container.Visible=true
Block.Visible=true

Button.BackgroundColor3=Library.BackgroundColor
Library.RegistryMap[Button].Properties.BackgroundColor3="BackgroundColor"

Tab:Resize()
end

function Tab.Hide(self)
Container.Visible=false
Block.Visible=false

Button.BackgroundColor3=Library.MainColor
Library.RegistryMap[Button].Properties.BackgroundColor3="MainColor"
end

function Tab.Resize(self)
local TabCount=0

for _,Tab in next,Tabbox.Tabs do
TabCount=TabCount+1
end

for _,Button in next,TabboxButtons:GetChildren()do
if not Button:IsA"UIListLayout"then
Button.Size=UDim2.new(1/TabCount,0,1,0)
end
end

if not Container.Visible then
return
end

local Size=0

for _,Element in next,Tab.Container:GetChildren()do
if(not Element:IsA"UIListLayout")and Element.Visible then
Size=Size+Element.Size.Y.Offset
end
end

BoxOuter.Size=UDim2.new(1,0,0,20+Size+2+2)
end

Button.InputBegan:Connect(function(Input)
if
Input.UserInputType==Enum.UserInputType.MouseButton1 and not Library:MouseIsOverOpenedFrame()
then
Tab:Show()
Tab:Resize()
end
end)

Tab.Container=Container
Tabbox.Tabs[Name]=Tab

setmetatable(Tab,BaseGroupbox)

Tab:AddBlank(3)
Tab:Resize()


if#TabboxButtons:GetChildren()==2 then
Tab:Show()
end

return Tab
end

Tab.Tabboxes[Info.Name or""]=Tabbox

return Tabbox
end

function Tab.AddLeftTabbox(self,Name)
return Tab:AddTabbox{Name=Name,Side=1}
end

function Tab.AddRightTabbox(self,Name)
return Tab:AddTabbox{Name=Name,Side=2}
end

TabButton.InputBegan:Connect(function(Input)
if Input.UserInputType==Enum.UserInputType.MouseButton1 then
Tab:ShowTab()
end
end)


if#TabContainer:GetChildren()==1 then
Tab:ShowTab()
end

Window.Tabs[Name]=Tab
return Tab
end

local ModalElement=Library:Create("TextButton",{
BackgroundTransparency=1,
Size=UDim2.new(0,0,0,0),
Visible=true,
Text="",
Modal=false,
Parent=ScreenGui,
})

function Library.UpdateAllRiskyToggles(self)
for _,Toggle in Toggles do
Toggle:UpdateRiskyState()
end
end

local TransparencyCache,
Toggled,
Fading={},false,false

function Library.Toggle(self)
if not Library.Alive or Fading then
return
end

local Lighting=game:FindService"Lighting"
local MenuBlur=Library.MenuBlur or Instance.new("BlurEffect",Lighting)
Library.MenuBlur=MenuBlur
MenuBlur.Name="MenuBlur"
MenuBlur.Size=0
MenuBlur.Enabled=true

local FadeTime=Library.ReducedMotion and 0 or Config.MenuFadeTime
TweenService:Create(MenuBlur,TweenInfo.new(FadeTime,Enum.EasingStyle.Sine,Enum.EasingDirection.Out),{Size=20}):Play()

Fading=true

Toggled=not Toggled
MenuBlur.Enabled=Toggled and not Library.ReducedMotion
Library.MenuVisible=Toggled
Library:ClosePopups()

ModalElement.Modal=Toggled

if Toggled then

Outer.Visible=true

task.spawn(function()
if Library.StandardCursor or not Library.Alive then return end
if not Drawing or type(Drawing.new)~="function"then
Library.StandardCursor=true
return
end
local State=InputService.MouseIconEnabled
Library.OriginalMouseIconEnabled=State

local Cursor,CursorOutline
local cursorOk,cursorError=pcall(function()
Cursor=Runtime.Own(Drawing.new"Triangle",function(value)value:Remove()end)
Cursor.Thickness=1
Cursor.Filled=true
Cursor.Visible=true
Cursor.ZIndex=9e8

CursorOutline=Runtime.Own(Drawing.new"Triangle",function(value)value:Remove()end)
CursorOutline.Thickness=1
CursorOutline.Filled=false
CursorOutline.Color=Color3.new(0,0,0)
CursorOutline.Visible=true
CursorOutline.ZIndex=9e8

while Library.Alive and Toggled and not Library.StandardCursor and ScreenGui.Parent do
InputService.MouseIconEnabled=false

local mPos=InputService:GetMouseLocation()

Cursor.Color=Library.AccentColor

Cursor.PointA=Vector2.new(mPos.X,mPos.Y)
Cursor.PointB=Vector2.new(mPos.X+16,mPos.Y+6)
Cursor.PointC=Vector2.new(mPos.X+6,mPos.Y+16)

CursorOutline.PointA=Cursor.PointA
CursorOutline.PointB=Cursor.PointB
CursorOutline.PointC=Cursor.PointC

RenderStepped:Wait()
end

end)
InputService.MouseIconEnabled=State
if Cursor then Runtime.Release(Cursor,true)end
if CursorOutline then Runtime.Release(CursorOutline,true)end
if not cursorOk then
Library.StandardCursor=true
Runtime.Record("menu cursor",cursorError)
end
end)
end

for _,Desc in next,Outer:GetDescendants()do
local Properties={}

if Desc:IsA"ImageLabel"then
table.insert(Properties,"ImageTransparency")
table.insert(Properties,"BackgroundTransparency")
elseif Desc:IsA"TextLabel"or Desc:IsA"TextBox"then
table.insert(Properties,"TextTransparency")
elseif Desc:IsA"Frame"or Desc:IsA"ScrollingFrame"then
table.insert(Properties,"BackgroundTransparency")
elseif Desc:IsA"UIStroke"then
table.insert(Properties,"Transparency")
end

local Cache=TransparencyCache[Desc]

if not Cache then
Cache={}
TransparencyCache[Desc]=Cache
end

for _,Prop in next,Properties do local __DARKLUA_CONTINUE_79=false repeat
if not Cache[Prop]then
Cache[Prop]=Desc[Prop]
end

if Cache[Prop]==1 then __DARKLUA_CONTINUE_79=true
break
end

TweenService:Create(
Desc,
TweenInfo.new(FadeTime,Enum.EasingStyle.Linear),
{[Prop]=Toggled and Cache[Prop]or 1}
):Play()__DARKLUA_CONTINUE_79=true until true if not __DARKLUA_CONTINUE_79 then break end
end
end

task.wait(FadeTime)

Outer.Visible=Toggled

Fading=false
end

Library:GiveSignal(InputService.InputBegan:Connect(function(Input,Processed)
if not Library.Alive or Processed or InputService:GetFocusedTextBox()or Library:IsNavigationKey(Input)then return end
if type(Library.ToggleKeybind)=="table"and Library.ToggleKeybind.Type=="KeyPicker"then
if
Input.UserInputType==Enum.UserInputType.Keyboard
and Input.KeyCode.Name==Library.ToggleKeybind.Value
then
task.spawn(Library.Toggle)
end
elseif
Input.KeyCode==Enum.KeyCode.RightControl or(Input.KeyCode==Enum.KeyCode.RightShift and not Processed)
then
task.spawn(Library.Toggle)
end
end))

if Config.AutoShow then
task.spawn(Library.Toggle)
end

Window.Holder=Outer

return Window
end local OnPlayerChange=function()


local PlayerList=GetPlayersString()

for _,Value in next,Options do
if Value.Type=="Dropdown"and Value.SpecialType=="Player"then
Value:SetValues(PlayerList)
end
end end


Library:GiveSignal(Players.PlayerAdded:Connect(OnPlayerChange))
Library:GiveSignal(Players.PlayerRemoving:Connect(OnPlayerChange))

getgenv().Library=Library
return Library end function init.i()local v=init.cache.i if not v then v={c=__modImpl()}init.cache.i=v end return v.c end end do local __modImpl=function()

return{
Library=init.i(),
}end function init.j()local v=init.cache.j if not v then v={c=__modImpl()}init.cache.j=v end return v.c end end do local __modImpl=function()
return{Snapshot="PlaceVersion 2266, 2026-08-15",Rows={{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale/korean_king1",Kind="Voice",Name="천세",Translation="Long live the king!",Asset="rbxassetid://6767456419",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale",LanguageGroup="Korean"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale/korean_king2",Kind="Voice",Name="천세",Translation="Long live the king!",Asset="rbxassetid://6767456359",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale",LanguageGroup="Korean"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale/korean_king3",Kind="Voice",Name="천세",Translation="Long live the king!",Asset="rbxassetid://6767456300",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale",LanguageGroup="Korean"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale/korean_nomistake",Kind="Voice",Name="한 치의 실수도 없어야 할 것이다",Translation="There must be no mistake!",Asset="rbxassetid://6767456221",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale",LanguageGroup="Korean"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale/korean_protect",Kind="Voice",Name="종묘와 사직을 바로 세울것이다",Translation="We will protect the kingdom!",Asset="rbxassetid://6767456121",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/KoreanMale",LanguageGroup="Korean"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_alabataille1",Kind="Voice",Name="A la bataille!",Translation="Into battle!",Asset="rbxassetid://9871300744",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_alabataille2",Kind="Voice",Name="A la bataille!",Translation="Into battle!",Asset="rbxassetid://9871300628",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_alabataille3",Kind="Voice",Name="A la bataille!",Translation="Into battle!",Asset="rbxassetid://9871300439",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_alatacke1",Kind="Voice",Name="A l'attaque!",Translation="Attack!",Asset="rbxassetid://9871307790",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_alatacke2",Kind="Voice",Name="A l'attaque!",Translation="Attack!",Asset="rbxassetid://9871310043",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_alatacke3",Kind="Voice",Name="A l'attaque!",Translation="Attack!",Asset="rbxassetid://9871308325",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_charge1",Kind="Voice",Name="Chargez!",Translation="Charge!",Asset="rbxassetid://9871321456",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_charge2",Kind="Voice",Name="Chargez!",Translation="Charge!",Asset="rbxassetid://9871321329",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_charge3",Kind="Voice",Name="Chargez!",Translation="Charge!",Asset="rbxassetid://9871321216",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_escrazes1",Kind="Voice",Name="Écrasez-les!",Translation="Crush them!",Asset="rbxassetid://9871326497",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_escrazes2",Kind="Voice",Name="Écrasez-les!",Translation="Crush them!",Asset="rbxassetid://9871326381",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_escrazes3",Kind="Voice",Name="Écrasez-les!",Translation="Crush them!",Asset="rbxassetid://9871326294",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_empereur1",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://9871331582",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_empereur2",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://9871331446",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_empereur3",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://9871331340",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_enavant1",Kind="Voice",Name="En avant!",Translation="Forward!",Asset="rbxassetid://9871338192",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_enavant2",Kind="Voice",Name="En avant!",Translation="Forward!",Asset="rbxassetid://9871338023",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_enavant3",Kind="Voice",Name="En avant!",Translation="Forward!",Asset="rbxassetid://9871337899",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_legarde1",Kind="Voice",Name="La garde meurt mais ne se rend pas!",Translation="The guard dies but never surrender!",Asset="rbxassetid://9871349194",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_legarde2",Kind="Voice",Name="La garde meurt mais ne se rend pas!",Translation="The guard dies but never surrender!",Asset="rbxassetid://9871344337",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_legarde3",Kind="Voice",Name="La garde meurt mais ne se rend pas!",Translation="The guard dies but never surrender!",Asset="rbxassetid://9871344191",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_legarde4",Kind="Voice",Name="La garde meurt mais ne se rend pas!",Translation="The guard dies but never surrender!",Asset="rbxassetid://9871349344",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_onvaleur1",Kind="Voice",Name="On va la percer leur flanc!",Translation="We will flank them!",Asset="rbxassetid://9871355237",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_onvaleur2",Kind="Voice",Name="On va la percer leur flanc!",Translation="We will flank them!",Asset="rbxassetid://9871355065",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_onvaleur3",Kind="Voice",Name="On va la percer leur flanc!",Translation="We will flank them!",Asset="rbxassetid://9871354963",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_tenezcette1",Kind="Voice",Name="Tenez cette position!",Translation="Hold this position!",Asset="rbxassetid://9871360883",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_tenezcette2",Kind="Voice",Name="Tenez cette position!",Translation="Hold this position!",Asset="rbxassetid://9871360811",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_tenezcette3",Kind="Voice",Name="Tenez cette position!",Translation="Hold this position!",Asset="rbxassetid://9871360715",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_ralliez1",Kind="Voice",Name="Rally!",Translation="Ralliez-vous!",Asset="rbxassetid://9871364056",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_ralliez2",Kind="Voice",Name="Rally!",Translation="Ralliez-vous!",Asset="rbxassetid://9871363906",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_ralliez3",Kind="Voice",Name="Rally!",Translation="Ralliez-vous!",Asset="rbxassetid://9871363790",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_tenezligne1",Kind="Voice",Name="Hold that line!",Translation="Tene cete ligne!",Asset="rbxassetid://9871367462",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_tenezligne2",Kind="Voice",Name="Hold that line!",Translation="Tene cete ligne!",Asset="rbxassetid://9871367380",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_tenezligne3",Kind="Voice",Name="Hold that line!",Translation="Tene cete ligne!",Asset="rbxassetid://9871367276",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_prepare1",Kind="Voice",Name="Preparez-vous!",Translation="Prepare yourselves!",Asset="rbxassetid://9871375902",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_prepare2",Kind="Voice",Name="Preparez-vous!",Translation="Prepare yourselves!",Asset="rbxassetid://9871375763",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_prepare3",Kind="Voice",Name="Preparez-vous!",Translation="Prepare yourselves!",Asset="rbxassetid://9871375650",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_courage1",Kind="Voice",Name="Soyez Courageux!",Translation="Be Brave!",Asset="rbxassetid://9871379632",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_courage2",Kind="Voice",Name="Soyez Courageux!",Translation="Be Brave!",Asset="rbxassetid://9871379785",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_vibatrie1",Kind="Voice",Name="Vive la Patrie!",Translation="Long live the fatherland!",Asset="rbxassetid://9871385815",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_vibatrie2",Kind="Voice",Name="Vive la Patrie!",Translation="Long live the fatherland!",Asset="rbxassetid://9871385695",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_vibatrie3",Kind="Voice",Name="Vive la Patrie!",Translation="Long live the fatherland!",Asset="rbxassetid://9871385540",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_vivala1",Kind="Voice",Name="Vive la France!",Translation="Long live France!",Asset="rbxassetid://8845118484",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_vivala2",Kind="Voice",Name="Vive la France!",Translation="Long live France!",Asset="rbxassetid://8845119094",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_vivala3",Kind="Voice",Name="Vive la France!",Translation="Long live France!",Asset="rbxassetid://8845119931",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_victoire1",Kind="Voice",Name="À la victoire!",Translation="To victory!",Asset="rbxassetid://9871470222",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_victoire2",Kind="Voice",Name="À la victoire!",Translation="To victory!",Asset="rbxassetid://9871379402",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_avantgarde1",Kind="Voice",Name="À l'avant-garde!",Translation="In the front!",Asset="rbxassetid://9871459890",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_avantgarde2",Kind="Voice",Name="À l'avant-garde!",Translation="In the front!",Asset="rbxassetid://9871463024",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_passeront1",Kind="Voice",Name="Ils ne passeront pas!",Translation="They shall not pass!",Asset="rbxassetid://9871475350",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_passeront2",Kind="Voice",Name="Ils ne passeront pas!",Translation="They shall not pass!",Asset="rbxassetid://9871475238",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_estanous1",Kind="Voice",Name="La victoire est à nous!",Translation="Victory is ours!",Asset="rbxassetid://9871480070",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_estanous2",Kind="Voice",Name="La victoire est à nous!",Translation="Victory is ours!",Asset="rbxassetid://9871479991",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_sanspeur1",Kind="Voice",Name="Sans peur!",Translation="No fear!",Asset="rbxassetid://9871445768",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_sanspeur2",Kind="Voice",Name="Sans peur!",Translation="No fear!",Asset="rbxassetid://9871445636",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_toujourspret1",Kind="Voice",Name="Toujours prêt!",Translation="Always ready!",Asset="rbxassetid://9871442276",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_toujourspret2",Kind="Voice",Name="Toujours prêt!",Translation="Always ready!",Asset="rbxassetid://9871442139",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_victorieux1",Kind="Voice",Name="Victorieux!",Translation="Victorious!",Asset="rbxassetid://9871437128",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale/fren_f_victorieux2",Kind="Voice",Name="Victorieux!",Translation="Victorious!",Asset="rbxassetid://9871437015",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchFemale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau/nassau_hoorah1",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://8970288640",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau",LanguageGroup="Nassau"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau/nassau_hoorah2",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://8970330742",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau",LanguageGroup="Nassau"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau/nassau_hoorah3",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://8970332486",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau",LanguageGroup="Nassau"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau/nassau_druckt",Kind="Voice",Name="Drückt die Attack!",Translation="Press the Attack!",Asset="rbxassetid://8970307038",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau",LanguageGroup="Nassau"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau/nassau_inden",Kind="Voice",Name="In den Nahkampf!",Translation="Charge!",Asset="rbxassetid://8970304256",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau",LanguageGroup="Nassau"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau/nassau_schlagt",Kind="Voice",Name="Schlägt Sie!",Translation="Charge!",Asset="rbxassetid://8970327726",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau",LanguageGroup="Nassau"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau/nassau_gott",Kind="Voice",Name="Gott schütze uns!",Translation="God save us!",Asset="rbxassetid://8970301826",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau",LanguageGroup="Nassau"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau/nassau_eslebe",Kind="Voice",Name="Es lebe der Herzog!",Translation="Long live the Duke!",Asset="rbxassetid://8970298801",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Nassau",LanguageGroup="Nassau"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_freih_1",Kind="Voice",Name="For the Duke!",Translation="For the Duke!",Asset="rbxassetid://11674131637",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_freih_2",Kind="Voice",Name="For the Duke!",Translation="For the Duke!",Asset="rbxassetid://11674055610",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_freih_3",Kind="Voice",Name="For God and Freiherr!",Translation="For God and Freiherr!",Asset="rbxassetid://10952706784",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_freih_4",Kind="Voice",Name="For God and Freiherr!",Translation="For God and Freiherr!",Asset="rbxassetid://10952707623",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_freih_5",Kind="Voice",Name="For God and Freiherr!",Translation="For God and Freiherr!",Asset="rbxassetid://10952708114",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_freih_6",Kind="Voice",Name="God is with us!",Translation="God is with us!",Asset="rbxassetid://10956859694",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_hoorah_1",Kind="Voice",Name="Hoorah ",Translation="Hoorah ",Asset="rbxassetid://11674064945",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_hoorah_2",Kind="Voice",Name="Hoorah ",Translation="Hoorah ",Asset="rbxassetid://11674064945",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_hoorah_3",Kind="Voice",Name="Hoorah ",Translation="Hoorah ",Asset="rbxassetid://11674064945",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_hoorah_4",Kind="Voice",Name="Hoorah ",Translation="Hoorah ",Asset="rbxassetid://11674064945",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_hoorah_5",Kind="Voice",Name="Hoorah ",Translation="Hoorah ",Asset="rbxassetid://11674064945",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_hoorah_6",Kind="Voice",Name="Hoorah ",Translation="Hoorah ",Asset="rbxassetid://11674064945",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_attack_1",Kind="Voice",Name="Angriff!",Translation="Attack!",Asset="rbxassetid://11674070844",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_attack_2",Kind="Voice",Name="Angriff!",Translation="Attack!",Asset="rbxassetid://11674070844",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_attack_3",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://11674070844",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_attack_4",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://11674070844",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_attack_5",Kind="Voice",Name="Crush them!",Translation="Crush them!",Asset="rbxassetid://10957843774",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_attack_6",Kind="Voice",Name="Crush them!",Translation="Crush them!",Asset="rbxassetid://10957844357",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_attack_7",Kind="Voice",Name="Attack",Translation="Attack",Asset="rbxassetid://10956860824",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_gold_1",Kind="Voice",Name="For gold and honor!",Translation="For gold and honor!",Asset="rbxassetid://10952704417",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_gold_2",Kind="Voice",Name="For gold and honor!",Translation="For gold and honor!",Asset="rbxassetid://10952705274",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_gold_3",Kind="Voice",Name="For gold and honor!",Translation="For gold and honor!",Asset="rbxassetid://10952705814",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_gold_4",Kind="Voice",Name="To the last man!",Translation="To the last man!",Asset="rbxassetid://11674083304",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_onwards_1",Kind="Voice",Name="Onwards! In the name of the Duke!",Translation="Onwards! In the name of the Duke!",Asset="rbxassetid://11674100638",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_onwards_2",Kind="Voice",Name="Onwards! In the name of the Duke!",Translation="Onwards! In the name of the Duke!",Asset="rbxassetid://11674100638",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_onwards_3",Kind="Voice",Name="Forward! For the Duke!",Translation="Forward! For the Duke!",Asset="rbxassetid://11674100638",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_onwards_4",Kind="Voice",Name="Forward! For the Duke!",Translation="Forward! For the Duke!",Asset="rbxassetid://11674100638",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_onwards_5",Kind="Voice",Name="This is for the Freiherr!",Translation="This is for the Freiherr!",Asset="rbxassetid://11674100638",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_onwards_6",Kind="Voice",Name="This is for the Freiherr!",Translation="This is for the Freiherr!",Asset="rbxassetid://11674100638",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_bayonet_1",Kind="Voice",Name="What? Never seen a bayonet before?",Translation="What? Never seen a bayonet before?",Asset="rbxassetid://10956662326",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_bayonet_2",Kind="Voice",Name="What? Never seen a bayonet before?",Translation="What? Never seen a bayonet before?",Asset="rbxassetid://10957819693",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_quick_1",Kind="Voice",Name="Quick keep going!",Translation="Quick keep going!",Asset="rbxassetid://10957824691",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale/andour_quick_2",Kind="Voice",Name="Quick keep going!",Translation="Quick keep going!",Asset="rbxassetid://10957825249",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranGermanMale",LanguageGroup="AndouranGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish/naples_killthem",Kind="Voice",Name="Zabijać!",Translation="Kill them!",Asset="rbxassetid://7878580625",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish",LanguageGroup="NaplesPolish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish/naples_forward1",Kind="Voice",Name="Naprzód!",Translation="Forward!",Asset="rbxassetid://7878582080",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish",LanguageGroup="NaplesPolish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish/naples_forward2",Kind="Voice",Name="Naprzód!",Translation="Forward!",Asset="rbxassetid://7878590751",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish",LanguageGroup="NaplesPolish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish/naples_die",Kind="Voice",Name="Gin!",Translation="Die!",Asset="rbxassetid://7878584531",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish",LanguageGroup="NaplesPolish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish/naples_defend",Kind="Voice",Name="Bronić się!",Translation="Defend yourselves!",Asset="rbxassetid://7878586038",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish",LanguageGroup="NaplesPolish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish/naples_dontgiveup",Kind="Voice",Name="Nie ustępować!",Translation="Don't give up!",Asset="rbxassetid://7878587425",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish",LanguageGroup="NaplesPolish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish/naples_hold",Kind="Voice",Name="Trwać na stanowiskach!",Translation="Hold the position!",Asset="rbxassetid://7878588216",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish",LanguageGroup="NaplesPolish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish/naples_takethat1",Kind="Voice",Name="A Masz!",Translation="Take that!",Asset="rbxassetid://9615981869",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish",LanguageGroup="NaplesPolish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish/naples_takethat2",Kind="Voice",Name="A Masz!",Translation="Take that!",Asset="rbxassetid://615981513",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesPolish",LanguageGroup="NaplesPolish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic/naples_god",Kind="Voice",Name="Allah Ahkbar!",Translation="God is the Greatest!",Asset="rbxassetid://12630750998",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic",LanguageGroup="NaplesArabic"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic/naples_hafathana",Kind="Voice",Name="Hafathana Allah!",Translation="God save us!",Asset="rbxassetid://12630756358",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic",LanguageGroup="NaplesArabic"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic/naples_hujum1",Kind="Voice",Name="Hujum!",Translation="Attack!",Asset="rbxassetid://12630753742",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic",LanguageGroup="NaplesArabic"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic/naples_hujum2",Kind="Voice",Name="Hujum!",Translation="Attack!",Asset="rbxassetid://12630754316",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic",LanguageGroup="NaplesArabic"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic/naples_amamila",Kind="Voice",Name="Illa al amam ila baghat illah!",Translation="Forwards to God's will!",Asset="rbxassetid://12630752847",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic",LanguageGroup="NaplesArabic"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic/naples_amam1",Kind="Voice",Name="Illa al amam!",Translation="Forward!",Asset="rbxassetid://12630749302",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic",LanguageGroup="NaplesArabic"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic/naples_amam2",Kind="Voice",Name="Illa al amam!",Translation="Forward!",Asset="rbxassetid://12630752222",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesArabic",LanguageGroup="NaplesArabic"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/totsu_1",Kind="Voice",Name="Koegki!",Translation="Attack!",Asset="rbxassetid://9013246977",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/totsu_2",Kind="Voice",Name="Shinai!",Translation="Die!",Asset="rbxassetid://9013249596",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/totsu_3",Kind="Voice",Name="Totsugeki!",Translation="Charge!",Asset="rbxassetid://9013251187",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/shogun_1",Kind="Voice",Name="Shogun no Tameni!",Translation="For the Shogun!",Asset="rbxassetid://9013268536",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/shogun_2",Kind="Voice",Name="Shogun no Tameni!",Translation="For the Shogun!",Asset="rbxassetid://9013270131",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/shogun_3",Kind="Voice",Name="Shogun no Tameni!",Translation="For the Shogun!",Asset="rbxassetid://9013271850",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/tenno_1",Kind="Voice",Name="Tennoheika Banzai!",Translation="Long Live The Emperor!",Asset="rbxassetid://9013283401",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/tenno_2",Kind="Voice",Name="Tennoheika Banzai!",Translation="Long Live The Emperor!",Asset="rbxassetid://9013284762",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/tenno_3",Kind="Voice",Name="Tennoheika Banzai!",Translation="Long Live The Emperor!",Asset="rbxassetid://9013285900",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/ei_1",Kind="Voice",Name="Ei Ei O!",Translation="Hurrah!",Asset="rbxassetid://9013305525",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/ei_2",Kind="Voice",Name="Ei Ei O!",Translation="Hurrah!",Asset="rbxassetid://9013307421",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/ei_3",Kind="Voice",Name="Ei Ei O!",Translation="Hurrah!",Asset="rbxassetid://9013308939",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/banzai_1",Kind="Voice",Name="Banzai!",Translation="Long Live!",Asset="rbxassetid://9013235042",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/clan_1",Kind="Voice",Name="Tokugawa no Tameni!",Translation="For the Tokugawa!",Asset="rbxassetid://9013311543",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/clan_2",Kind="Voice",Name="Chosokabe no Tameni!",Translation="For the Chosokabe!",Asset="rbxassetid://9013313271",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/clan_3",Kind="Voice",Name="Takeda no Tameni!",Translation="For the Takeda!",Asset="rbxassetid://9013323281",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/clan_4",Kind="Voice",Name="Shimazu no Tameni!",Translation="For the Shimazu!",Asset="rbxassetid://9013325867",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/clan_5",Kind="Voice",Name="Oda no Tameni!",Translation="For the Oda!",Asset="rbxassetid://9013328261",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/clan_6",Kind="Voice",Name="Ii no Tameni!",Translation="For the Ii!",Asset="rbxassetid://9013330567",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale/clan_7",Kind="Voice",Name="Honda no Tameni!",Translation="For the Honda!",Asset="rbxassetid://9013332184",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseFemale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/totsu_1",Kind="Voice",Name="Koegki!",Translation="Attack!",Asset="rbxassetid://9012531436",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/totsu_2",Kind="Voice",Name="Shinai!",Translation="Die!",Asset="rbxassetid://9012535672",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/totsu_3",Kind="Voice",Name="Totsugeki!",Translation="Charge!",Asset="rbxassetid://9012538399",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/shogun_1",Kind="Voice",Name="Shogun no Tameni!",Translation="For the Shogun!",Asset="rbxassetid://9012551679",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/shogun_2",Kind="Voice",Name="Shogun no Tameni!",Translation="For the Shogun!",Asset="rbxassetid://9012552493",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/tenno_1",Kind="Voice",Name="Tennoheika Banzai!",Translation="Long Live The Emperor!",Asset="rbxassetid://9012553817",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/tenno_2",Kind="Voice",Name="Tennoheika Banzai!",Translation="Long Live The Emperor!",Asset="rbxassetid://9012554986",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/tenno_3",Kind="Voice",Name="Tennoheika Banzai!",Translation="Long Live The Emperor!",Asset="rbxassetid://9012556092",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/ei_1",Kind="Voice",Name="Ei Ei O!",Translation="Hurrah!",Asset="rbxassetid://9012641760",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/ei_2",Kind="Voice",Name="Ei Ei O!",Translation="Hurrah!",Asset="rbxassetid://9012643099",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/ei_3",Kind="Voice",Name="Ei Ei O!",Translation="Hurrah!",Asset="rbxassetid://9012644019",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/banzai_1",Kind="Voice",Name="Banzai!",Translation="Long Live!",Asset="rbxassetid://9012651657",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/banzai_2",Kind="Voice",Name="Banzai!",Translation="Long Live!",Asset="rbxassetid://9012652569",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/banzai_3",Kind="Voice",Name="Banzai!",Translation="Long Live!",Asset="rbxassetid://9012653593",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/clan_1",Kind="Voice",Name="Tokugawa no Tameni!",Translation="For the Tokugawa!",Asset="rbxassetid://9012707249",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/clan_2",Kind="Voice",Name="Chosokabe no Tameni!",Translation="For the Chosokabe!",Asset="rbxassetid://9012705791",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/clan_3",Kind="Voice",Name="Takeda no Tameni!",Translation="For the Takeda!",Asset="rbxassetid://9012708996",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/clan_4",Kind="Voice",Name="Shimazu no Tameni!",Translation="For the Shimazu!",Asset="rbxassetid://9012731341",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/clan_5",Kind="Voice",Name="Oda no Tameni!",Translation="For the Oda!",Asset="rbxassetid://9012731968",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/clan_6",Kind="Voice",Name="Ii no Tameni!",Translation="For the Ii!",Asset="rbxassetid://9013656178",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale/clan_7",Kind="Voice",Name="Honda no Tameni!",Translation="For the Honda!",Asset="rbxassetid://9012746096",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/JapaneseMale",LanguageGroup="Japanese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_nosey1",Kind="Voice",Name="Hurrah For Old Nosey!",Translation="Hurrah For Old Nosey!",Asset="rbxassetid://12667893919",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_nosey2",Kind="Voice",Name="Hurrah For Old Nosey!",Translation="Hurrah For Old Nosey!",Asset="rbxassetid://12667894149",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_kingandcountry1",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://12667910077",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_kingandcountry2",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://12667909598",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_kingandcountry3",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://12667909051",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_britannia1",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://12668267428",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_britannia2",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://12668267698",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_makeway1",Kind="Voice",Name="Make Way for the King's Guard!",Translation="Make Way for the King's Guard!",Asset="rbxassetid://12670410932",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_makeway2",Kind="Voice",Name="Make Way for the King's Guard!",Translation="Make Way for the King's Guard!",Asset="rbxassetid://12670411242",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_huzzah1",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://12668027785",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_huzzah2",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://12668027472",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_bydand1",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://12668066896",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_bydand2",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://12668066655",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_bydand3",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://12668066367",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_sons1",Kind="Voice",Name="Sons of the Hounds!",Translation="Sons of the Hounds!",Asset="rbxassetid://12668095513",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_sons2",Kind="Voice",Name="Sons of the Hounds!",Translation="Sons of the Hounds!",Asset="rbxassetid://12668095907",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_god1",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://12668125176",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_god2",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://12668124803",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale/scottish_god3",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://12668125020",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishGuardMale",LanguageGroup="ScottishGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_brothers1",Kind="Voice",Name="All Together brothers!",Translation="? ? ?",Asset="rbxassetid://7881329653",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_brothers2",Kind="Voice",Name="All Together brothers!",Translation="? ? ?",Asset="rbxassetid://7881330836",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_brothers3",Kind="Voice",Name="All Together brothers!",Translation="? ? ?",Asset="rbxassetid://7881332027",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_brothers4",Kind="Voice",Name="All Together brothers!",Translation="? ? ?",Asset="rbxassetid://7881333276",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_saragossa1",Kind="Voice",Name="Remember Saragossa Brothers!",Translation="? ? ?",Asset="rbxassetid://7881315698",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_saragossa2",Kind="Voice",Name="Remember Saragossa Brothers!",Translation="? ? ?",Asset="rbxassetid://7881317388",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_saragossa3",Kind="Voice",Name="Remember Saragossa Brothers!",Translation="? ? ?",Asset="rbxassetid://7881318915",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_saragossa4",Kind="Voice",Name="Remember Saragossa Brothers!",Translation="? ? ?",Asset="rbxassetid://7881322806",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_god1",Kind="Voice",Name="God save the Grand Duke!",Translation="? ? ?",Asset="rbxassetid://7881304419",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_god2",Kind="Voice",Name="God save the Grand Duke!",Translation="? ? ?",Asset="rbxassetid://7881305718",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_god3",Kind="Voice",Name="God save the Grand Duke!",Translation="? ? ?",Asset="rbxassetid://7881307895",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_god4",Kind="Voice",Name="God save the Grand Duke!",Translation="? ? ?",Asset="rbxassetid://7881309084",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_lion1",Kind="Voice",Name="Raise the Lion Banner!",Translation="? ? ?",Asset="rbxassetid://7881299949",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_lion2",Kind="Voice",Name="Raise the Lion Banner!",Translation="? ? ?",Asset="rbxassetid://7881300977",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_lion3",Kind="Voice",Name="Raise the Lion Banner!",Translation="? ? ?",Asset="rbxassetid://7881302172",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_duke1",Kind="Voice",Name="For the Grand Duke!",Translation="? ? ?",Asset="rbxassetid://7881294383",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_duke2",Kind="Voice",Name="For the Grand Duke!",Translation="? ? ?",Asset="rbxassetid://7881295591",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_duke3",Kind="Voice",Name="For the Grand Duke!",Translation="? ? ?",Asset="rbxassetid://7881296776",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_duke4",Kind="Voice",Name="For the Grand Duke!",Translation="? ? ?",Asset="rbxassetid://7881298058",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_hoorah1",Kind="Voice",Name="Hoorah!",Translation="? ? ?",Asset="rbxassetid://8443164274",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_hoorah2",Kind="Voice",Name="Hoorah",Translation="? ? ?",Asset="rbxassetid://8443165517",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_hoorah3",Kind="Voice",Name="Hoorah",Translation="? ? ?",Asset="rbxassetid://8443166748",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_hoorah4",Kind="Voice",Name="Hoorah",Translation="? ? ?",Asset="rbxassetid://8500893313",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_hoorah5",Kind="Voice",Name="Hoorah",Translation="? ? ?",Asset="rbxassetid://8500895089",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_forhessen1",Kind="Voice",Name="For Hessen!",Translation="? ? ?",Asset="rbxassetid://7881273805",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_forhessen2",Kind="Voice",Name="For Hessen!",Translation="? ? ?",Asset="rbxassetid://7881275777",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_forhessen3",Kind="Voice",Name="For Hessen!",Translation="? ? ?",Asset="rbxassetid://7881277109",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale/hesse_forhessen4",Kind="Voice",Name="For Hessen!",Translation="? ? ?",Asset="rbxassetid://7881278879",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HessianMale",LanguageGroup="Hessian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale/port_pela_1",Kind="Voice",Name="Pela Patria!",Translation="Pela Patria!",Asset="rbxassetid://9379379575",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale/port_pelo_1",Kind="Voice",Name="Pela Rei!",Translation="Pela Rei!",Asset="rbxassetid://9379380316",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale/port_por_1",Kind="Voice",Name="Por Deus!",Translation="Por Deus!",Asset="rbxassetid://9379380972",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale/port_seDeus_1",Kind="Voice",Name="Se Deus Quiser!",Translation="Se Deus Quiser!",Asset="rbxassetid://9379381562",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale/port_armas_1",Kind="Voice",Name="Armas na Mão!",Translation="Armas na Mão!",Asset="rbxassetid://9379377294",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale/port_marchar_1",Kind="Voice",Name="Marchar para Frente!",Translation="Marchar para Frente!",Asset="rbxassetid://9379378862",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale/port_deusPatria_1",Kind="Voice",Name="Deus, Patria, Rei!",Translation="Deus, Patria, Rei!",Asset="rbxassetid://9379377991",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseFemale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_viva1",Kind="Voice",Name="Viva Portugal!",Translation="Long live Portugal!",Asset="rbxassetid://16895935921",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_viva2",Kind="Voice",Name="Viva Portugal!",Translation="Long live Portugal!",Asset="rbxassetid://16895862663",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_viva3",Kind="Voice",Name="Viva Portugal!",Translation="Long live Portugal!",Asset="rbxassetid://16895936540",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_carga1",Kind="Voice",Name="À Carga!",Translation="Charge!",Asset="rbxassetid://16895857220",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_carga2",Kind="Voice",Name="À Carga!",Translation="Charge!",Asset="rbxassetid://16895856744",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_carga3",Kind="Voice",Name="À Carga!",Translation="Charge!",Asset="rbxassetid://16897562570",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_carga4",Kind="Voice",Name="À Carga!",Translation="Charge!",Asset="rbxassetid://16897563084",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_carga5",Kind="Voice",Name="À Carga!",Translation="Charge!",Asset="rbxassetid://16897707472",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_batalha1",Kind="Voice",Name="A Batalha!",Translation="To battle!",Asset="rbxassetid://16897562849",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_batalha2",Kind="Voice",Name="A Batalha!",Translation="To battle!",Asset="rbxassetid://16897563319",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_vidalonga",Kind="Voice",Name="Vida longa ao Rei!",Translation="Long live the king!",Asset="rbxassetid://16895862251",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_pela1",Kind="Voice",Name="Pela Gloria!",Translation="For Glory!",Asset="rbxassetid://16895855877",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_pela2",Kind="Voice",Name="Pela Honra e Pela Gloria!",Translation="For Honour and for Glory!",Asset="rbxassetid://16895852166",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_vitoria",Kind="Voice",Name="A Vitoria e nossa!",Translation="Victory is ours!",Asset="rbxassetid://16895856507",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_vitoria2",Kind="Voice",Name="A Vitoria e nossa!",Translation="Victory is ours!",Asset="rbxassetid://16895855531",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_vitoria3",Kind="Voice",Name="A Vitoria e nossa!",Translation="Victory is ours!",Asset="rbxassetid://16896027018",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_armas1",Kind="Voice",Name="Armas na Mao!",Translation="Get ready!",Asset="rbxassetid://16895856232",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_armas2",Kind="Voice",Name="Armas na Mao!",Translation="Get ready!",Asset="rbxassetid://16895851715",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_levantar",Kind="Voice",Name="Levantar a Bandeira!",Translation="Raise the colours!",Asset="rbxassetid://16895853733",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_vivarei",Kind="Voice",Name="Viva o Rei!",Translation="Long Live the King!",Asset="rbxassetid://16895853096",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_deuspatria1",Kind="Voice",Name="Deus Patria e Rei!",Translation="For God, Country, and King!",Asset="rbxassetid://16895854744",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_deuspatria2",Kind="Voice",Name="Deus Patria e Rei!",Translation="For God, Country, and King!",Asset="rbxassetid://16895854119",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_depressa",Kind="Voice",Name="Ao ataque depressa!",Translation="Strike Swiftly!",Asset="rbxassetid://16895854996",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_antesamorte",Kind="Voice",Name="Antes a morte que a desonra!!",Translation="Rather Death than Dishonour!",Asset="rbxassetid://16895855254",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale/port_gloria",Kind="Voice",Name="Glora ou Morte!",Translation="Glory or Death!",Asset="rbxassetid://16896027364",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PortugueseMale",LanguageGroup="Portuguese"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie/zombie_growl_01",Kind="Voice",Name="Urughhh",Translation="Urughhh",Asset="rbxassetid://11423209443",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie",LanguageGroup="Zombie"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie/zombie_growl_02",Kind="Voice",Name="Auurgh",Translation="Aurggh",Asset="rbxassetid://11423209132",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie",LanguageGroup="Zombie"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie/zombie_growl_03",Kind="Voice",Name="Uuurgh..",Translation="Uuurgh",Asset="rbxassetid://11423208915",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie",LanguageGroup="Zombie"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie/zombie_hurt_01",Kind="Voice",Name="Aughsh",Translation="Aughsh",Asset="rbxassetid://11423209626",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie",LanguageGroup="Zombie"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie/zombie_hurt_02",Kind="Voice",Name="Aueegh",Translation="Aueegh",Asset="rbxassetid://11423208692",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Zombie",LanguageGroup="Zombie"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_hurrah1",Kind="Voice",Name="Hurra!",Translation="Hurrah!",Asset="rbxassetid://72872007785312",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_hurrah2",Kind="Voice",Name="Hurra!",Translation="Hurrah!",Asset="rbxassetid://100803236178690",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_hurrah3",Kind="Voice",Name="Hurra!",Translation="Hurrah!",Asset="rbxassetid://116345576731570",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_hurrah4",Kind="Voice",Name="Hurra!",Translation="Hurrah!",Asset="rbxassetid://107852296413436",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_godcause1",Kind="Voice",Name="For Gud og den retfærdige sag!",Translation="For God, and the righteous cause!",Asset="rbxassetid://125747903933801",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_godcause2",Kind="Voice",Name="For Gud og den retfærdige sag!",Translation="For God, and the righteous cause!",Asset="rbxassetid://70721444146473",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_godcause3",Kind="Voice",Name="For Gud og den retfærdige sag!",Translation="For God, and the righteous cause!",Asset="rbxassetid://78847349779107",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_kingcountry1",Kind="Voice",Name="For kongen og riget!",Translation="For King and Country!",Asset="rbxassetid://132477467122787",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_kingcountry2",Kind="Voice",Name="For kongen og riget!",Translation="For King and Country!",Asset="rbxassetid://104639838682226",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_kingcountry3",Kind="Voice",Name="For kongen og riget!",Translation="For King and Country!",Asset="rbxassetid://75367491294989",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_attack1",Kind="Voice",Name="Angreb!",Translation="Attack!",Asset="rbxassetid://113451064746764",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_attack2",Kind="Voice",Name="Angreb!",Translation="Attack!",Asset="rbxassetid://135177597855777",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_attack3",Kind="Voice",Name="Angreb!",Translation="Attack!",Asset="rbxassetid://129594484484335",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_hell1",Kind="Voice",Name="Giv dem helvede!",Translation="Give them hell!",Asset="rbxassetid://86366587233310",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_hell2",Kind="Voice",Name="Giv dem helvede!",Translation="Give them hell!",Asset="rbxassetid://78664299067158",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_hell3",Kind="Voice",Name="Giv dem helvede!",Translation="Give them hell!",Asset="rbxassetid://125452039309986",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_forward1",Kind="Voice",Name="Fremad!",Translation="Forward!",Asset="rbxassetid://127867554016444",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_forward2",Kind="Voice",Name="Fremad!",Translation="Forward!",Asset="rbxassetid://125709338826495",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_forward3",Kind="Voice",Name="Fremad!",Translation="Forward!",Asset="rbxassetid://106913446890888",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_king1",Kind="Voice",Name="Gud bevare kongen!",Translation="God save the king!",Asset="rbxassetid://129237496243563",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_king2",Kind="Voice",Name="Gud bevare kongen!",Translation="God save the king!",Asset="rbxassetid://138301851766382",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_king3",Kind="Voice",Name="Gud bevare kongen!",Translation="God save the king!",Asset="rbxassetid://135455764663973",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_fortune1",Kind="Voice",Name="Lykken står de modige!",Translation="Fortune favours the brave!",Asset="rbxassetid://131065436160780",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_fortune2",Kind="Voice",Name="Lykken står de modige!",Translation="Fortune favours the brave!",Asset="rbxassetid://86058348435478",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale/danish_fortune3",Kind="Voice",Name="Lykken står de modige!",Translation="Fortune favours the brave!",Asset="rbxassetid://133652806296457",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DanishMale",LanguageGroup="Danish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Wiwat_cesarz1",Kind="Voice",Name="Wiwat cesarz!",Translation="Long live the emperor!",Asset="rbxassetid://8983510279",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Wiwat_cesarz2",Kind="Voice",Name="Wiwat cesarz!",Translation="Long live the emperor!",Asset="rbxassetid://8983497795",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Niech_zyje_cesarz_1",Kind="Voice",Name="Niech żyje cesarz!",Translation="Long live the emperor!",Asset="rbxassetid://8983499698",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Niech_zyje_cesarz_2",Kind="Voice",Name="Niech żyje cesarz!",Translation="Long live the emperor!",Asset="rbxassetid://8983499369",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Niech_zyje_wodz_1",Kind="Voice",Name="Niech żyje wódz!",Translation="Long live the chief!",Asset="rbxassetid://8983499046",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Niech_zyje_wodz_2",Kind="Voice",Name="Niech żyje wódz!",Translation="Long live the chief!",Asset="rbxassetid://8983498854",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Do_ataku1",Kind="Voice",Name="Do ataku!",Translation="Attack!",Asset="rbxassetid://8983894484",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Do_ataku2",Kind="Voice",Name="Do ataku!",Translation="Attack!",Asset="rbxassetid://8983502766",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Do_boju1",Kind="Voice",Name="Do boju!",Translation="To battle!",Asset="rbxassetid://8983502621",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Do_boju2",Kind="Voice",Name="Do boju!",Translation="To battle!",Asset="rbxassetid://8983502407",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Na_nich_bracia1",Kind="Voice",Name="Na nich bracia, do ataku!",Translation="At them brothers, attack!",Asset="rbxassetid://8983500558",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Na_nich_bracia2",Kind="Voice",Name="Na nich bracia, do ataku!",Translation="At them brothers, attack!",Asset="rbxassetid://8983500294",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Szarza1",Kind="Voice",Name="Szarża!",Translation="Charge!",Asset="rbxassetid://8983498363",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Szarza2",Kind="Voice",Name="Szarża!",Translation="Charge!",Asset="rbxassetid://8983498233",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Za_mna_chlopcy_1",Kind="Voice",Name="Za mną chłopcy, do szarży!",Translation="Follow me boys, charge!",Asset="rbxassetid://8983496773",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Za_mna_chlopcy_2",Kind="Voice",Name="Za mną chłopcy, do szarży!",Translation="Follow me boys, charge!",Asset="rbxassetid://8983504074",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Za_ojczyzne1",Kind="Voice",Name="Za ojczyznę!",Translation="For fatherland!",Asset="rbxassetid://8983496235",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Za_ojczyzne2",Kind="Voice",Name="Za ojczyznę!",Translation="For fatherland!",Asset="rbxassetid://8983496014",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Za_chwale1",Kind="Voice",Name="Za chwałę!",Translation="For glory!",Asset="rbxassetid://8983497562",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Za_chwale2",Kind="Voice",Name="Za chwałę!",Translation="For glory!",Asset="rbxassetid://8983497399",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Za_honor_i_chwale1",Kind="Voice",Name="Za honor i chwałę!",Translation="For honor and glory!",Asset="rbxassetid://8983497233",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Za_honor_i_chwale2",Kind="Voice",Name="Za honor i chwałę!",Translation="For honor and glory!",Asset="rbxassetid://8983496984",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Hurra1",Kind="Voice",Name="Hurra!",Translation="Hurra!",Asset="rbxassetid://8983511595",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Hurra2",Kind="Voice",Name="Hurra!",Translation="Hurra!",Asset="rbxassetid://8983501889",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Hurra_hurra1",Kind="Voice",Name="Hurra, hurra!",Translation="Hurra, hurra!",Asset="rbxassetid://8983506882",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Hurra_hurra2",Kind="Voice",Name="Hurra, hurra!",Translation="Hurra, hurra!",Asset="rbxassetid://8983501334",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Scierwo1",Kind="Voice",Name="Ścierwo!",Translation="Scum!",Asset="rbxassetid://8983498675",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Scierwo2",Kind="Voice",Name="Ścierwo!",Translation="Scum!",Asset="rbxassetid://8983498522",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Kanalie1",Kind="Voice",Name="Mam nadzieję że was to zaboli kanalie!",Translation="I hope this hurts you scum!",Asset="rbxassetid://8983501138",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Kanalie2",Kind="Voice",Name="Mam nadzieję że was to zaboli kanalie!",Translation="I hope this hurts you scum!",Asset="rbxassetid://8983500862",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Nedzne_kundle1",Kind="Voice",Name="Nędzne kundle!",Translation="Wretched mongrels!",Asset="rbxassetid://8983500052",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale/Nedzne_kundle2",Kind="Voice",Name="Nędzne kundle!",Translation="Wretched mongrels!",Asset="rbxassetid://8983499863",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishFemale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_legarde1",Kind="Voice",Name="La garde meurt mais ne se rend pas!",Translation="The guard dies but never surrender!",Asset="rbxassetid://8847411244",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_legarde2",Kind="Voice",Name="La garde meurt mais ne se rend pas!",Translation="The guard dies but never surrender!",Asset="rbxassetid://8847411086",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_legarde3",Kind="Voice",Name="La garde meurt mais ne se rend pas!",Translation="The guard dies but never surrender!",Asset="rbxassetid://8847410924",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_alabataille1",Kind="Voice",Name="A la bataille!",Translation="Into battle!",Asset="rbxassetid://8848605816",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_alabataille2",Kind="Voice",Name="A la bataille!",Translation="Into battle!",Asset="rbxassetid://8848605589",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_alatacke1",Kind="Voice",Name="A l'attaque!",Translation="Attack!",Asset="rbxassetid://8848954428",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_alatacke2",Kind="Voice",Name="A l'attaque!",Translation="Attack!",Asset="rbxassetid://8848954692",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_alatacke3",Kind="Voice",Name="A l'attaque!",Translation="Attack!",Asset="rbxassetid://8848954225",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_charge1",Kind="Voice",Name="Chargez!",Translation="Charge!",Asset="rbxassetid://8848659630",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_charge2",Kind="Voice",Name="Chargez!",Translation="Charge!",Asset="rbxassetid://8848659267",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_charge3",Kind="Voice",Name="Chargez!",Translation="Charge!",Asset="rbxassetid://8848660081",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_escrazes1",Kind="Voice",Name="Écrasez-les!",Translation="Crush them!",Asset="rbxassetid://8847882662",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_escrazes2",Kind="Voice",Name="Écrasez-les!",Translation="Crush them!",Asset="rbxassetid://8847882372",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_escrazes3",Kind="Voice",Name="Écrasez-les!",Translation="Crush them!",Asset="rbxassetid://8847882559",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_empereur1",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://8848752109",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_empereur2",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://8848752109",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_empereur3",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://8848752591",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_empereur4",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://8848752420",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_enavant1",Kind="Voice",Name="En avant!",Translation="Forward!",Asset="rbxassetid://8847795813",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_enavant2",Kind="Voice",Name="En avant!",Translation="Forward!",Asset="rbxassetid://8847796246",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_enavant3",Kind="Voice",Name="En avant!",Translation="Forward!",Asset="rbxassetid://8847796076",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_onvaleur1",Kind="Voice",Name="On va la percer leur flanc!",Translation="We will flank them!",Asset="rbxassetid://8849207856",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_onvaleur2",Kind="Voice",Name="On va la percer leur flanc!",Translation="We will flank them!",Asset="rbxassetid://8849207633",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_tenezcette1",Kind="Voice",Name="Tenez cette position!",Translation="Hold this position!",Asset="rbxassetid://8849283044",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_tenezcette2",Kind="Voice",Name="Tenez cette position!",Translation="Hold this position!",Asset="rbxassetid://8849282693",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_tenezcette3",Kind="Voice",Name="Tenez cette position!",Translation="Hold this position!",Asset="rbxassetid://8849282087",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_ralliez1",Kind="Voice",Name="Rally!",Translation="Ralliez-vous!",Asset="rbxassetid://8849404535",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_ralliez2",Kind="Voice",Name="Rally!",Translation="Ralliez-vous!",Asset="rbxassetid://8849404289",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_ralliez3",Kind="Voice",Name="Rally!",Translation="Ralliez-vous!",Asset="rbxassetid://8849404037",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_tenezligne1",Kind="Voice",Name="Hold that line!",Translation="Tene cete ligne!",Asset="rbxassetid://8849475326",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_tenezligne2",Kind="Voice",Name="Hold that line!",Translation="Tene cete ligne!",Asset="rbxassetid://8849475155",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_tenezligne3",Kind="Voice",Name="Hold that line!",Translation="Tene cete ligne!",Asset="rbxassetid://8849474899",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_prepare1",Kind="Voice",Name="Preparez-vous!",Translation="Prepare yourselves!",Asset="rbxassetid://8849518337",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_prepare2",Kind="Voice",Name="Preparez-vous!",Translation="Prepare yourselves!",Asset="rbxassetid://8849518161",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_prepare3",Kind="Voice",Name="Preparez-vous!",Translation="Prepare yourselves!",Asset="rbxassetid://8849517946",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_courage1",Kind="Voice",Name="Soyez Courageux!",Translation="Be Brave!",Asset="rbxassetid://8849561579",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_courage2",Kind="Voice",Name="Soyez Courageux!",Translation="Be Brave!",Asset="rbxassetid://8849561390",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_vibatrie1",Kind="Voice",Name="Vive la Patrie!",Translation="Long live the fatherland!",Asset="rbxassetid://8847740406",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_vibatrie2",Kind="Voice",Name="Vive la Patrie!",Translation="Long live the fatherland!",Asset="rbxassetid://8847740695",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_vibatrie3",Kind="Voice",Name="Vive la Patrie!",Translation="Long live the fatherland!",Asset="rbxassetid://8847740140",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_vivala1",Kind="Voice",Name="Vive la France!",Translation="Long live France!",Asset="rbxassetid://8845118484",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_vivala2",Kind="Voice",Name="Vive la France!",Translation="Long live France!",Asset="rbxassetid://8845119094",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_vivala3",Kind="Voice",Name="Vive la France!",Translation="Long live France!",Asset="rbxassetid://8845119931",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_victoire1",Kind="Voice",Name="À la victoire!",Translation="To victory!",Asset="rbxassetid://5801524773",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_avantgarde1",Kind="Voice",Name="À l'avant-garde!",Translation="In the front!",Asset="rbxassetid://5801525106",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_passeront1",Kind="Voice",Name="Ils ne passeront pas!",Translation="They shall not pass!",Asset="rbxassetid://5801525446",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_gardeenavant1",Kind="Voice",Name="La garde, en avant!",Translation="Guard, forward!",Asset="rbxassetid://5801525651",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_estanous1",Kind="Voice",Name="La victoire est à nous!",Translation="Victory is ours!",Asset="rbxassetid://5801525903",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_sanspeur1",Kind="Voice",Name="Sans peur!",Translation="No fear!",Asset="rbxassetid://5801526218",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_toujourspret1",Kind="Voice",Name="Toujours prêt!",Translation="Always ready!",Asset="rbxassetid://5801526441",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale/fren_victorieux1",Kind="Voice",Name="Victorieux!",Translation="Victorious!",Asset="rbxassetid://5801526729",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchMale",LanguageGroup="French"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_taunting",Kind="Voice",Name="Sarın Köpekler!",Translation="Dirty dogs!",Asset="rbxassetid://12249816962",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_celebration",Kind="Voice",Name="Yaşasın, Zafer, Yaşasın!",Translation="Long live, victory, long live!",Asset="rbxassetid://12249816854",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_celebration2",Kind="Voice",Name="Yaşasın, Yaşasın!",Translation="Long live! Long live!",Asset="rbxassetid://12249817031",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_allah1",Kind="Voice",Name="Allah! Allah! Allah!",Translation="Allah! Allah! Allah!",Asset="rbxassetid://12522671927",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_allah2",Kind="Voice",Name="Allah!",Translation="Allah!",Asset="rbxassetid://12522671987",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_allah3",Kind="Voice",Name="Allah! Allah!",Translation="Allah! Allah!",Asset="rbxassetid://12522672049",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_allah4",Kind="Voice",Name="Allah! Allah! Allah!",Translation="Allah! Allah! Allah!",Asset="rbxassetid://130502951916470",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_allah5",Kind="Voice",Name="Allahu Ekber!",Translation="God is great!",Asset="rbxassetid://82193899141704",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_allah6",Kind="Voice",Name="Allah Affedicidir!",Translation="God is forgiving!",Asset="rbxassetid://73555025837044",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_zafer",Kind="Voice",Name="Zafer!",Translation="Victory!",Asset="rbxassetid://12522715330",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_attack",Kind="Voice",Name="Saldırın!",Translation="Attack!",Asset="rbxassetid://122118923171440",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/turkish_charge",Kind="Voice",Name="Hücum!",Translation="Charge!",Asset="rbxassetid://140079487498164",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_hu",Kind="Voice",Name="Hû!",Translation="Horrah!",Asset="rbxassetid://119209885177148",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_hu2",Kind="Voice",Name="Hû!",Translation="Horrah!",Asset="rbxassetid://100019130259455",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_hu3",Kind="Voice",Name="Hû!",Translation="Horrah!",Asset="rbxassetid://123304086964617",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_hu4",Kind="Voice",Name="Hû!",Translation="Horrah!",Asset="rbxassetid://133442078685024",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_hu5",Kind="Voice",Name="Hû!",Translation="Horrah!",Asset="rbxassetid://129391494191313",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_hu6",Kind="Voice",Name="Hû!",Translation="Horrah!",Asset="rbxassetid://71998247071290",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_hu7",Kind="Voice",Name="Hû!",Translation="Horrah!",Asset="rbxassetid://103893544180682",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_hu8",Kind="Voice",Name="Hû!",Translation="Horrah!",Asset="rbxassetid://117885701954540",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_praise",Kind="Voice",Name="Allahü Ekber!",Translation="God is the greatest!",Asset="rbxassetid://76963067739256",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_praise2",Kind="Voice",Name="Allahü Ekber!",Translation="God is the greatest!",Asset="rbxassetid://70402636600489",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_battlecry",Kind="Voice",Name="Allahallah!",Translation="Allahallah!",Asset="rbxassetid://92668933321357",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_battlecry2",Kind="Voice",Name="Allahallah!",Translation="Allahallah!",Asset="rbxassetid://82629437557369",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_battlecry3",Kind="Voice",Name="Allahallah!",Translation="Allahallah!",Asset="rbxassetid://136087431096451",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_battlecry5",Kind="Voice",Name="Allahallah!",Translation="Allahallah!",Asset="rbxassetid://71077128301013",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_charge",Kind="Voice",Name="Hücum!",Translation="Charge!",Asset="rbxassetid://119429415990349",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_victory1",Kind="Voice",Name="Kilicimiz Düsmana Ziyân!",Translation="Our sword defeats the enemy!",Asset="rbxassetid://86905540318803",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_victory2",Kind="Voice",Name="Zafer!",Translation="Victory!",Asset="rbxassetid://114773860332565",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_sultan",Kind="Voice",Name="Kullugumuz Padisaha Ayân!",Translation="We serve the Sultan!",Asset="rbxassetid://105337498939222",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_fatherland1",Kind="Voice",Name="Yasasin Vatan!",Translation="Long live the fatherland!",Asset="rbxassetid://95395907603197",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_fatherland2",Kind="Voice",Name="Yasasin!",Translation="Hoorah!",Asset="rbxassetid://109459780807419",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_forward1",Kind="Voice",Name="Yallah!",Translation="Let's go!",Asset="rbxassetid://137586875817426",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale/ottoman_forward2",Kind="Voice",Name="Haydi Yallah!",Translation="Come on, let's go!",Asset="rbxassetid://93605333673462",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TurkishMale",LanguageGroup="Turkish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_hurrah2",Kind="Voice",Name="¡Raaaaahhh!",Translation="Raaaaahhh!",Asset="rbxassetid://13442728084",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_hurrah3",Kind="Voice",Name="¡Hurrah!",Translation="Hurrah!",Asset="rbxassetid://13442727752",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_hurrah4",Kind="Voice",Name="¡Huuuraaahh!",Translation="Huuuraaahh!",Asset="rbxassetid://13442727400",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_hurrah5",Kind="Voice",Name="¡Hurahahahaha!",Translation="Hurahahahaha!",Asset="rbxassetid://13442727597",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_hurrah6",Kind="Voice",Name="¡Hurrah!",Translation="Hurrah!",Asset="rbxassetid://13442726981",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_hurrah7",Kind="Voice",Name="¡Hurrah, hurrah!",Translation="Hurrah, hurrah!",Asset="rbxassetid://13442727938",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_crush1",Kind="Voice",Name="¡Áplastenlos!",Translation="Crush them!",Asset="rbxassetid://13442835248",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_crush2",Kind="Voice",Name="¡Áplastenlos!",Translation="Crush them!",Asset="rbxassetid://13442835046",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_crush3",Kind="Voice",Name="¡Áplastenlos como moscas!",Translation="Crush them like flies!",Asset="rbxassetid://13442836276",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_crush4",Kind="Voice",Name="¡Áplastenlos como moscas!",Translation="Crush them like flies!",Asset="rbxassetid://13442835791",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_crush5",Kind="Voice",Name="¡Destrúyanlos!",Translation="Destroy them!",Asset="rbxassetid://13442835428",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_crush7",Kind="Voice",Name="¡Hah, son presa facil!",Translation="Hah, they are easy prey!",Asset="rbxassetid://13442835560",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_crush8",Kind="Voice",Name="¡Muéstrales quiénes somos!",Translation="Show them who we are!",Asset="rbxassetid://13442834863",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_attack1",Kind="Voice",Name="¡Destruidlos, hijos de España!",Translation="Destroy them, sons of Spain!",Asset="rbxassetid://13442963862",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_attack2",Kind="Voice",Name="¡A la carga!",Translation="Charge!",Asset="rbxassetid://13442964678",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_attack3",Kind="Voice",Name="¡A la carga!",Translation="Charge!",Asset="rbxassetid://13442964426",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_attack4",Kind="Voice",Name="¡Vamos, por Espana!",Translation="Lets go, for Spain!",Asset="rbxassetid://13442964552",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_attack5",Kind="Voice",Name="¡A por los infieles!",Translation="Lets go after the infidels!",Asset="rbxassetid://13442970485",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_attack6",Kind="Voice",Name="¡Al ataque deprisa!",Translation="Attack quickly!",Asset="rbxassetid://13442963480",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_attack7",Kind="Voice",Name="¡Por el Rey, al ataque!",Translation="For the King, attack!",Asset="rbxassetid://13442964313",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_attack8",Kind="Voice",Name="¡Por el Rey, al ataque!",Translation="For the King, attack!",Asset="rbxassetid://13442964146",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_king1",Kind="Voice",Name="¡Viva el Rey!",Translation="Long live the King!",Asset="rbxassetid://13443000339",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_king2",Kind="Voice",Name="¡Viva el Rey!",Translation="Long live the King!",Asset="rbxassetid://13442999977",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_king3",Kind="Voice",Name="¡Viva Fernando!",Translation="Long live Fernando!",Asset="rbxassetid://13442999374",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_king4",Kind="Voice",Name="¡Viva Fernando VII!",Translation="Long live Fernando VII!",Asset="rbxassetid://13442999554",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_king5",Kind="Voice",Name="¡Por el Rey!",Translation="For the King!",Asset="rbxassetid://13442999126",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_king6",Kind="Voice",Name="¡Por la patria y el Rey!",Translation="For King and country!",Asset="rbxassetid://13443000155",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_king7",Kind="Voice",Name="¡Larga vida a Fernando VII!",Translation="Long live Fernando VII!",Asset="rbxassetid://13442999780",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_king8",Kind="Voice",Name="¡Por nuestro Rey!",Translation="For our King!",Asset="rbxassetid://13442999261",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_glory1",Kind="Voice",Name="¡Ganar o morir!",Translation="For glory!",Asset="rbxassetid://13445142308",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_glory2",Kind="Voice",Name="¡Buen día para luchar!",Translation="Today is a good day to fight!",Asset="rbxassetid://13445142441",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_glory3",Kind="Voice",Name="¡Buen día para luchar!",Translation="Today is a good day to fight!",Asset="rbxassetid://13445142084",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_glory4",Kind="Voice",Name="¡Para ganar o morir!",Translation="Victory or death!",Asset="rbxassetid://13445142686",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_glory5",Kind="Voice",Name="¡Antes morir que sufrir una deshonra!",Translation="Death before dishonor!",Asset="rbxassetid://13445141749",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_glory6",Kind="Voice",Name="¡Que el Señor nos proteja!",Translation="May the lord protect us!",Asset="rbxassetid://13445141891",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_glory7",Kind="Voice",Name="¡Muerte a los lobos franceses!",Translation="Death to the French wolves!",Asset="rbxassetid://13445141460",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_glory8",Kind="Voice",Name="¡Que Dios y Santiago nos ayuden!",Translation="May God and Santiago aid us!",Asset="rbxassetid://13445141610",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_withme1",Kind="Voice",Name="¡Conmigo!",Translation="With me!",Asset="rbxassetid://13445177184",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_withme2",Kind="Voice",Name="¡Conmigo!",Translation="With me!",Asset="rbxassetid://13445176842",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_withme3",Kind="Voice",Name="¡Vamos vamos moveos!",Translation="Lets go, lets go!",Asset="rbxassetid://13445177410",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_withme4",Kind="Voice",Name="¡Reagrúpense!",Translation="Regroup!",Asset="rbxassetid://13445176589",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_withme5",Kind="Voice",Name="¡Ándale, ándale!",Translation="Go, go, go!",Asset="rbxassetid://13445175906",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_withme6",Kind="Voice",Name="¡Ándale, ándale!",Translation="Go, go, go!",Asset="rbxassetid://13445176359",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_withme7",Kind="Voice",Name="¡Adelante!",Translation="Go ahead!",Asset="rbxassetid://13445177038",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_withme8",Kind="Voice",Name="¡Cierren filas!",Translation="Close the ranks!",Asset="rbxassetid://13445176156",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_spain1",Kind="Voice",Name="¡Viva España!",Translation="For Spain!",Asset="rbxassetid://13445230956",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_spain2",Kind="Voice",Name="¡Arriba y a por ellos, hermanos!",Translation="Up and at them Brothers!",Asset="rbxassetid://13445231328",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_spain3",Kind="Voice",Name="¡España no se rinde!",Translation="Spain does not surrender!",Asset="rbxassetid://13445230447",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_spain4",Kind="Voice",Name="¡España no se rinde!",Translation="Spain does not surrender!",Asset="rbxassetid://13445230598",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_spain5",Kind="Voice",Name="¡Santiago y cierra, España!",Translation="Santiago and strike, Spain!",Asset="rbxassetid://13445230310",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_spain6",Kind="Voice",Name="¡Viva España y viva el Rey!",Translation="For King and country!",Asset="rbxassetid://13445231146",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_spain7",Kind="Voice",Name="¡España, nunca serás vencida!",Translation="Spain shall never be defeated!",Asset="rbxassetid://13445230788",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_spain8",Kind="Voice",Name="¡España no se rinde!",Translation="Spain does not surrender!",Asset="rbxassetid://13445230061",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_misc1",Kind="Voice",Name="¡Dios es Español!",Translation="God is Spanish!",Asset="rbxassetid://13445261876",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_misc2",Kind="Voice",Name="¡Nadie se espera la Inquisición Española!",Translation="No one expects the Spanish Inquisition!",Asset="rbxassetid://13445262114",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_misc3",Kind="Voice",Name="¡Nadie se espera la Inquisición Española!",Translation="No one expects the Spanish Inquisition!",Asset="rbxassetid://13445262567",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_misc4",Kind="Voice",Name="¡Santiago y cierra España!",Translation="Santiago and strike, Spain!",Asset="rbxassetid://13445261429",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_misc5",Kind="Voice",Name="¡Rahahahahahaha!",Translation="Rahahahahahaha!",Asset="rbxassetid://13442727179",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale/spanish_misc8",Kind="Voice",Name="¡Santiago!",Translation="Santiago!",Asset="rbxassetid://13445262767",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SpanishMale",LanguageGroup="Spanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Wiwat_cesarz1",Kind="Voice",Name="Wiwat cesarz!",Translation="Long live the emperor!",Asset="rbxassetid://110808757613751",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Wiwat_cesarz2",Kind="Voice",Name="Za cesarza!",Translation="For the emperor!",Asset="rbxassetid://85154962575180",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Niech_zyje_cesarz_1",Kind="Voice",Name="Niech żyje cesarz!",Translation="Long live the emperor!",Asset="rbxassetid://78114047685006",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Niech_zyje_cesarz_2",Kind="Voice",Name="Niech żyje cesarz!",Translation="Long live the emperor!",Asset="rbxassetid://100757827410454",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Niech_zyje_wodz_1",Kind="Voice",Name="Niech żyje wódz!",Translation="Long live the chief!",Asset="rbxassetid://105316348199408",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Niech_zyje_wodz_2",Kind="Voice",Name="Wódz jest z nami!",Translation="The chief is with us!",Asset="rbxassetid://95230765711744",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Niech_zyje_wodz_3",Kind="Voice",Name="Za wodza!",Translation="Long live the chief!",Asset="rbxassetid://94894159853968",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Niech_zyje_wodz_4",Kind="Voice",Name="Za wodza!",Translation="Long live the chief!",Asset="rbxassetid://104237411234560",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Do_ataku1",Kind="Voice",Name="Do ataku!",Translation="Attack!",Asset="rbxassetid://83222759723826",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Naprzod1",Kind="Voice",Name="Naprzód!",Translation="Forward!",Asset="rbxassetid://106276862731321",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Naprzod2",Kind="Voice",Name="Naprzód!",Translation="Forward!",Asset="rbxassetid://87100792199602",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Do_boju1",Kind="Voice",Name="Do boju!",Translation="To battle!",Asset="rbxassetid://75081664185457",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Do_boju2",Kind="Voice",Name="Do boju!",Translation="To battle!",Asset="rbxassetid://74388008275923",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Na_nich_bracia1",Kind="Voice",Name="Na nich bracia, do ataku!",Translation="At them brothers, attack!",Asset="rbxassetid://123851632993482",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Szarza1",Kind="Voice",Name="Szarża!",Translation="Charge!",Asset="rbxassetid://114813490632627",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Szarza2",Kind="Voice",Name="Szarża!",Translation="Charge!",Asset="rbxassetid://112035444983098",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Dalej_chlopcy1",Kind="Voice",Name="Dalej chłopcy, do szarży!",Translation="With me boys, charge!",Asset="rbxassetid://113390120972708",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Dalej_chlopcy2",Kind="Voice",Name="Za mną chłopcy!",Translation="With me boys!",Asset="rbxassetid://75876898245209",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Dalej_chlopcy3",Kind="Voice",Name="Dalej chłopcy, ku zwycięstwu!",Translation="Come on boys, forward!",Asset="rbxassetid://113028021789995",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Z_Boza1",Kind="Voice",Name="Z Bożą pomocą, naprzód!",Translation="With God's help, forward!",Asset="rbxassetid://79052031862392",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Bij1",Kind="Voice",Name="Bij! Kto w Boga wierzy!",Translation="Fight, those who believe in god!",Asset="rbxassetid://101944517704313",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Za_ojczyzne1",Kind="Voice",Name="Za ojczyznę!",Translation="For the fatherland!",Asset="rbxassetid://136999529875564",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Za_ojczyzne2",Kind="Voice",Name="Za ojczyznę!",Translation="For the fatherland!",Asset="rbxassetid://82680104417848",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Za_ojczyzne3",Kind="Voice",Name="Niech żyje Polska!",Translation="Long live Poland!",Asset="rbxassetid://88072325191978",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Za_ojczyzne4",Kind="Voice",Name="Jeszcze Polska nie zginęła!",Translation="Poland is not yet lost!",Asset="rbxassetid://78401739060878",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Za_ojczyzne5",Kind="Voice",Name="Wiwat Rzeczpospolita!",Translation="Long live the Commonwealth!",Asset="rbxassetid://124731334260378",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Za_chwale1",Kind="Voice",Name="Za chwałę!",Translation="For glory!",Asset="rbxassetid://85987358206604",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Za_honor_i_chwale1",Kind="Voice",Name="Za honor i chwałę!",Translation="For honor and glory!",Asset="rbxassetid://77639699224521",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Hurra1",Kind="Voice",Name="Hip hip hurra!",Translation="Hurra!",Asset="rbxassetid://89252454358009",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Hurra2",Kind="Voice",Name="Hip hip hurra!",Translation="Hurra!",Asset="rbxassetid://126708255842763",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Hurra3",Kind="Voice",Name="Hurra, hurra!",Translation="Hurra, hurra!",Asset="rbxassetid://90890042488851",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Hurra4",Kind="Voice",Name="Hurra, hurra, hurra!",Translation="Hurra, hurra, hurra!",Asset="rbxassetid://105738899900157",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Hurra5",Kind="Voice",Name="Hurra!",Translation="Hurra!",Asset="rbxassetid://116184629741656",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Scierwo1",Kind="Voice",Name="Ścierwo!",Translation="Scum!",Asset="rbxassetid://132850114080302",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Diabla_nimi1",Kind="Voice",Name="Do diabła z nimi!",Translation="To the devil with them!",Asset="rbxassetid://135521328860966",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Hundsfoty1",Kind="Voice",Name="Hundsfoty!",Translation="Sons of the hounds!",Asset="rbxassetid://89576257082733",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Kanalie1",Kind="Voice",Name="Mam nadzieję, że was to zaboli kanalie!",Translation="I hope this hurts you, scum!",Asset="rbxassetid://122203838781371",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Nedzne_kundle1",Kind="Voice",Name="Nędzne kundle!",Translation="Wretched mongrels!",Asset="rbxassetid://114961735053337",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale/Chowaja1",Kind="Voice",Name="Chowają się za spódnicami!",Translation="They are hiding like schoolgirls!",Asset="rbxassetid://114276172650369",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PolishMale",LanguageGroup="Polish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_connaught1",Kind="Voice",Name="To Hell or to Connaught!",Translation="To Hell or to Connaught!",Asset="rbxassetid://17456423973",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_huzzah1",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://17456286305",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_huzzah2",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://17456392917",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_godsave1",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://17456397977",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_faugh1",Kind="Voice",Name="Faugh a Ballagh!",Translation="Clear the Way!",Asset="rbxassetid://17456402399",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_faugh2",Kind="Voice",Name="Faugh a Ballaugh!",Translation="Clear the Way!",Asset="rbxassetid://17456407028",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_buaidh1",Kind="Voice",Name="Buaidh no Bas!",Translation="Conquer or Die!",Asset="rbxassetid://17456409016",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_dia1",Kind="Voice",Name="Dia Shabhail Eire!",Translation="God Save Ireland!",Asset="rbxassetid://17456415734",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_charge1",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://17456436925",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale/BritishIrish_linn1",Kind="Voice",Name="Dia Linn!",Translation="God Be With Us!",Asset="rbxassetid://17456445332",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishIrishMale",LanguageGroup="BritishIrish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/dutch_hoera1",Kind="Voice",Name="Hoera!",Translation="Hurrah!",Asset="rbxassetid://5221960825",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/dutch_niemand1",Kind="Voice",Name="Niemand zal ons verslaan!",Translation="No One Can Defeat Us!",Asset="rbxassetid://5221961429",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/dutch_vuila1",Kind="Voice",Name="Vuila honden!",Translation="Dirty Dogs!",Asset="rbxassetid://5221962669",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/dutch_victorie1",Kind="Voice",Name="Victorie!",Translation="Victory!",Asset="rbxassetid://5221961960",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/dutch_victorie2",Kind="Voice",Name="Victorie!",Translation="Victory!",Asset="rbxassetid://5221963144",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/dutch_glorie1",Kind="Voice",Name="Voor eer en Glorie!",Translation="For Honour and Glory!",Asset="rbxassetid://893614772",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/dutch_liever1",Kind="Voice",Name="Liever dood dan eerloos!",Translation="Better dead than dishonorable!",Asset="rbxassetid://893617766",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/dutch_aanvallen1",Kind="Voice",Name="Aanvallen!",Translation="Attack!",Asset="rbxassetid://893620511",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/fren_empereur1",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://8848752109",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/fren_empereur2",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://8848752591",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/fren_empereur3",Kind="Voice",Name="Vive l'Empereur!",Translation="Long live the Emperor!",Asset="rbxassetid://8848752420",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/Dutch_legarde1",Kind="Voice",Name="De Garde sterft maar geeft zich nooit over!",Translation="The guard dies but never surrender!",Asset="rbxassetid://8847411244",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/Dutch_legarde2",Kind="Voice",Name="De Garde sterft maar geeft zich nooit over!",Translation="The guard dies but never surrender!",Asset="rbxassetid://8847411086",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale/Dutch_legarde3",Kind="Voice",Name="De Garde sterft maar geeft zich nooit over!",Translation="The guard dies but never surrender!",Asset="rbxassetid://8847410924",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/DutchMale",LanguageGroup="Dutch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_dia1",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://5988860298",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_dia2",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://5988860624",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_dia3",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://5988860997",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_erin1",Kind="Voice",Name="Erin go Bragh!",Translation="Ireland Forever!",Asset="rbxassetid://5988861675",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_erin2",Kind="Voice",Name="Erin go Bragh!",Translation="Ireland Forever!",Asset="rbxassetid://5988862017",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_erin3",Kind="Voice",Name="Erin go Bragh!",Translation="Ireland Forever!",Asset="rbxassetid://5988862481",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_nar1",Kind="Voice",Name="Nár laga Dhia thú!",Translation="May God Protect You!",Asset="rbxassetid://5988862798",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_nar2",Kind="Voice",Name="Nár laga Dhia thú!",Translation="May God Protect You!",Asset="rbxassetid://5988863066",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_nar3",Kind="Voice",Name="Nár laga Dhia thú!",Translation="May God Protect You!",Asset="rbxassetid://5988864229",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_abu1",Kind="Voice",Name="Abú!",Translation="Forever!",Asset="rbxassetid://5988856983",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_abu2",Kind="Voice",Name="Abú!",Translation="Forever!",Asset="rbxassetid://5988857644",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_abu3",Kind="Voice",Name="Abú!",Translation="Forever!",Asset="rbxassetid://5988858778",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_saorise1",Kind="Voice",Name="Saoirse nó Bás!",Translation="Freedom or Death!",Asset="rbxassetid://5988859181",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_saorise2",Kind="Voice",Name="Saoirse nó Bás!",Translation="Freedom or Death!",Asset="rbxassetid://5988859543",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale/irish_saorise3",Kind="Voice",Name="Saoirse nó Bás!",Translation="Freedom or Death!",Asset="rbxassetid://5988859841",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishMale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_charge1",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://79344646878018",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_charge2",Kind="Voice",Name="Drive them back!",Translation="Drive them back!",Asset="rbxassetid://90071011243887",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_charge3",Kind="Voice",Name="They're retreating, advance!",Translation="They're retreating, advance!",Asset="rbxassetid://101009002810031",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_charge4",Kind="Voice",Name="Forward!",Translation="Forward!",Asset="rbxassetid://80879516187313",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_hurrah1",Kind="Voice",Name="Hurrah!",Translation="Hurrah!",Asset="rbxassetid://132771816089748",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_hurrah2",Kind="Voice",Name="Hurrah, hurrah!",Translation="Hurrah, hurrah!",Asset="rbxassetid://108075903626541",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_hurrah3",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://110728588704563",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_hurrah4",Kind="Voice",Name="Oorah!",Translation="Oorah!",Asset="rbxassetid://74919460241644",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_kneel1",Kind="Voice",Name="We kneel to none!",Translation="We kneel to none!",Asset="rbxassetid://74128181351035",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_kneel2",Kind="Voice",Name="Come take it!",Translation="Come take it!",Asset="rbxassetid://108090239660028",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_kneel3",Kind="Voice",Name="You call that courage?",Translation="You call that courage?",Asset="rbxassetid://77925725224534",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_kneel4",Kind="Voice",Name="Death before dishonour!",Translation="Death before dishonour!",Asset="rbxassetid://124935368853933",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_liberty1",Kind="Voice",Name="For liberty!",Translation="For liberty!",Asset="rbxassetid://109558100408728",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_liberty2",Kind="Voice",Name="No Kings, no crown!",Translation="No Kings, no crown!!",Asset="rbxassetid://71924653517209",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_liberty3",Kind="Voice",Name="For the Republic!",Translation="For liberty!",Asset="rbxassetid://123658226366034",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_liberty4",Kind="Voice",Name="Give me liberty or give me death!",Translation="Give me liberty or give me death!",Asset="rbxassetid://87771783940543",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_liberty5",Kind="Voice",Name="Freedom or death!",Translation="Freedom or death!",Asset="rbxassetid://112389997288289",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_liberty6",Kind="Voice",Name="Give 'em a taste of liberty!",Translation="Give 'em a taste of liberty!",Asset="rbxassetid://132825767951588",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_god1",Kind="Voice",Name="God bless America!",Translation="God bless America!",Asset="rbxassetid://127418416637889",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_god2",Kind="Voice",Name="God bless America!",Translation="God bless America!",Asset="rbxassetid://103556838506982",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_god3",Kind="Voice",Name="In God we trust!",Translation="In God we trust!",Asset="rbxassetid://88575227136161",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_line1",Kind="Voice",Name="Hold the line!",Translation="Hold the line!",Asset="rbxassetid://135781223184197",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_line2",Kind="Voice",Name="Stand firm!",Translation="Stand firm!",Asset="rbxassetid://120801197149248",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_bayonets",Kind="Voice",Name="Fix bayonets!",Translation="Fix bayonets!",Asset="rbxassetid://78768903303141",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_republic",Kind="Voice",Name="The Republic stands on your shoulders!",Translation="The Republic stands on your shoulders!",Asset="rbxassetid://71230016486519",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_blimey1",Kind="Voice",Name="Blimey scum!",Translation="Blimey scum!",Asset="rbxassetid://85924136847366",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale/america_blimey2",Kind="Voice",Name="Blimey scum!",Translation="Blimey scum!",Asset="rbxassetid://72020111950577",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMale",LanguageGroup="American"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_dia1",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://6483297320",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_dia2",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://6483297879",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_dia3",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://6483298319",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_dia4",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://6483298674",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_erin1",Kind="Voice",Name="Erin go Bragh!",Translation="Ireland Forever!",Asset="rbxassetid://6459375307",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_erin2",Kind="Voice",Name="Erin go Bragh!",Translation="Ireland Forever!",Asset="rbxassetid://6459376283",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_nar1",Kind="Voice",Name="Nár laga Dhia thú!",Translation="May God Protect You!",Asset="rbxassetid://6459378104",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_nar2",Kind="Voice",Name="Nár laga Dhia thú!",Translation="May God Protect You!",Asset="rbxassetid://6459378795",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_nar3",Kind="Voice",Name="Nár laga Dhia thú!",Translation="May God Protect You!",Asset="rbxassetid://6459379469",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_abu1",Kind="Voice",Name="Abú!",Translation="Forever!",Asset="rbxassetid://6459370219",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_abu2",Kind="Voice",Name="Abú!",Translation="Forever!",Asset="rbxassetid://6459370851",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_abu3",Kind="Voice",Name="Abú!",Translation="Forever!",Asset="rbxassetid://6459371232",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_saorise1",Kind="Voice",Name="Saoirse nó Bás!",Translation="Freedom or Death!",Asset="rbxassetid://6459371619",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_saorise2",Kind="Voice",Name="Saoirse nó Bás!",Translation="Freedom or Death!",Asset="rbxassetid://6459372148",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale/irish_f_saorise3",Kind="Voice",Name="Saoirse nó Bás!",Translation="Freedom or Death!",Asset="rbxassetid://6459372748",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishFemale",LanguageGroup="Irish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_eternal_1",Kind="Voice",Name="Andour Eternal!",Translation="Andour Eternal!",Asset="rbxassetid://9073536669",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_eternal_2",Kind="Voice",Name="Andour Eternal!",Translation="Andour Eternal!",Asset="rbxassetid://9073537258",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_eternal_3",Kind="Voice",Name="Andour Eternal!",Translation="Andour Eternal!",Asset="rbxassetid://9073538014",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_citadel_1",Kind="Voice",Name="The Citadel Stands Tall!",Translation="The Citadel Stands Tall!",Asset="rbxassetid://9073538684",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_citadel_2",Kind="Voice",Name="The Citadel Stands Tall!",Translation="The Citadel Stands Tall!",Asset="rbxassetid://9073539020",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_citadel_3",Kind="Voice",Name="The Citadel Stands Tall!",Translation="The Citadel Stands Tall!",Asset="rbxassetid://9073539367",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_name_1",Kind="Voice",Name="In The Name of The High King!",Translation="In The Name of The High King!",Asset="rbxassetid://9073539870",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_name_2",Kind="Voice",Name="In The Name of The High King!",Translation="In The Name of The High King!",Asset="rbxassetid://9073540360",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_name_3",Kind="Voice",Name="In The Name of The High King!",Translation="In The Name of The High King!",Asset="rbxassetid://9073541166",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_way_1",Kind="Voice",Name="The Way Forwards is Paved With Glory!",Translation="The Way Forwards is Paved With Glory!",Asset="rbxassetid://9073544265",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_way_2",Kind="Voice",Name="The Way Forwards is Paved With Glory!",Translation="The Way Forwards is Paved With Glory!",Asset="rbxassetid://9073543568",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_way_3",Kind="Voice",Name="The Way Forwards is Paved With Glory!",Translation="The Way Forwards is Paved With Glory!",Asset="rbxassetid://9073543030",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_sunman_1",Kind="Voice",Name="Sunman Grant Us Strength!",Translation="Sunman Grant Us Strength!",Asset="rbxassetid://9073545698",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_sunman_2",Kind="Voice",Name="Sunman Grant Us Strength!",Translation="Sunman Grant Us Strength!",Asset="rbxassetid://9073545171",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_sunman_3",Kind="Voice",Name="Sunman Grant Us Strength!",Translation="Sunman Grant Us Strength!",Asset="rbxassetid://9073544779",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_glory_1",Kind="Voice",Name="Alghrim's Glory!",Translation="Alghrim's Glory!",Asset="rbxassetid://9073535864",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_glory_2",Kind="Voice",Name="Alghrim's Glory!",Translation="Alghrim's Glory!",Asset="rbxassetid://9073534501",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_glory_3",Kind="Voice",Name="Alghrim's Glory!",Translation="Alghrim's Glory!",Asset="rbxassetid://9073533824",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_purge_1",Kind="Voice",Name="To Purge the Malfeasance!",Translation="To Purge the Malfeasance!",Asset="rbxassetid://9073541748",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale/andour_purge_2",Kind="Voice",Name="To Purge the Malfeasance!",Translation="To Purge the Malfeasance!",Asset="rbxassetid://9073542211",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranMale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_gloria",Kind="Voice",Name="Per la gloria!",Translation="?",Asset="rbxassetid://990513431",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_carica1",Kind="Voice",Name="Carica!",Translation="?",Asset="rbxassetid://990517159",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_onore",Kind="Voice",Name="Per l'onore e la gloria!",Translation="?",Asset="rbxassetid://990514077",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_loro1",Kind="Voice",Name="Schiantateli!",Translation="?",Asset="rbxassetid://990515907",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_loro2",Kind="Voice",Name="Attack!",Translation="?",Asset="rbxassetid://12589594986",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_morti",Kind="Voice",Name="Gloria o morte!",Translation="?",Asset="rbxassetid://990514864",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_prima",Kind="Voice",Name="Meglio la morte che il disonore!",Translation="?",Asset="rbxassetid://990515293",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_hurrah1",Kind="Voice",Name="Hurrah!",Translation="?",Asset="rbxassetid://12589597965",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_hurrah2",Kind="Voice",Name="Hurrah Hurrah!",Translation="?",Asset="rbxassetid://12589598741",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_avanti",Kind="Voice",Name="Avanti!",Translation="?",Asset="rbxassetid://12589596919",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_vittoria1",Kind="Voice",Name="Vittoria!",Translation="?",Asset="rbxassetid://12589600436",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_vittoria2",Kind="Voice",Name="Vittoria!",Translation="?",Asset="rbxassetid://12589593223",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_guardia",Kind="Voice",Name="La Guardia non si arrende!",Translation="?",Asset="rbxassetid://13897499476",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale/italy_guardia2",Kind="Voice",Name="La Guardia non si arrende!",Translation="?",Asset="rbxassetid://13897499529",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianMale",LanguageGroup="Italian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_perish1",Kind="Voice",Name="They shall perish!",Translation="They shall perish!",Asset="rbxassetid://10216005906",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_perish2",Kind="Voice",Name="They shall perish!",Translation="They shall perish!",Asset="rbxassetid://10216005310",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_perish3",Kind="Voice",Name="They shall perish!",Translation="They shall perish!",Asset="rbxassetid://10216004484",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_mercy1",Kind="Voice",Name="No mercy!",Translation="No mercy!",Asset="rbxassetid://10216003824",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_mercy2",Kind="Voice",Name="No mercy!",Translation="No mercy!",Asset="rbxassetid://10216003090",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_mercy3",Kind="Voice",Name="No mercy!",Translation="No mercy!",Asset="rbxassetid://10216002274",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_horrah1",Kind="Voice",Name="Horrah!",Translation="Horrah!",Asset="rbxassetid://10215999761",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_horrah2",Kind="Voice",Name="Horrah!",Translation="Horrah!",Asset="rbxassetid://10215998916",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_horrah3",Kind="Voice",Name="Horrah!",Translation="Horrah!",Asset="rbxassetid://10215998359",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Forwardcomrades1",Kind="Voice",Name="Forward comrades!",Translation="Forward comrades!",Asset="rbxassetid://10215997449",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Forwardcomrades2",Kind="Voice",Name="Forward comrades!",Translation="Forward comrades!",Asset="rbxassetid://10215996692",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Forwardcomrades3",Kind="Voice",Name="Forward comrades!",Translation="Forward comrades!",Asset="rbxassetid://10215995705",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Forwardboys1",Kind="Voice",Name="Forward boys!",Translation="Forward boys!",Asset="rbxassetid://10215995021",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Forwardboys2",Kind="Voice",Name="Forward boys!",Translation="Forward boys!",Asset="rbxassetid://10215994364",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Forwardboys3",Kind="Voice",Name="Forward boys!",Translation="Forward boys!",Asset="rbxassetid://10215994364",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Fatherland1",Kind="Voice",Name="For the Fatherland!",Translation="For the Fatherland!",Asset="rbxassetid://10215992913",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Fatherland2",Kind="Voice",Name="For the Fatherland!",Translation="For the Fatherland!",Asset="rbxassetid://10215992359",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Fatherland3",Kind="Voice",Name="For the Fatherland!",Translation="For the Fatherland!",Asset="rbxassetid://10215991754",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_ForTheEmperor1",Kind="Voice",Name="For the Emperor!",Translation="For the Emperor!",Asset="rbxassetid://10215988920",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_ForTheEmperor2",Kind="Voice",Name="For the Emperor!",Translation="For the Emperor!",Asset="rbxassetid://10215989425",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_ForTheEmperor3",Kind="Voice",Name="For the Emperor!",Translation="For the Emperor!",Asset="rbxassetid://10215990885",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Followmeboys1",Kind="Voice",Name="Follow me boys!",Translation="Follow me boys!",Asset="rbxassetid://10215988196",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Followmeboys2",Kind="Voice",Name="Follow me boys!",Translation="Follow me boys!",Asset="rbxassetid://10215986391",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Destroythem1",Kind="Voice",Name="Destroy them!",Translation="Destroy them!",Asset="rbxassetid://10215983971",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Destroythem2",Kind="Voice",Name="Destroy them!",Translation="Destroy them!",Asset="rbxassetid://10215983102",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Destroythem3",Kind="Voice",Name="Destroy them!",Translation="Destroy them!",Asset="rbxassetid://10215981799",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Charge1",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://10215974031",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Charge2",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://10215973158",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Charge3",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://10215972347",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Attack1",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://10215971569",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Attack2",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://10215970924",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale/Prussian_Attack3",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://10215969732",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PrussianMale",LanguageGroup="Prussian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_swinehunde",Kind="Voice",Name="Swinehunde!",Translation="Pig-dogs!",Asset="rbxassetid://11821815553",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_swinehunde1",Kind="Voice",Name="Swinehunde!",Translation="Pig-dogs!",Asset="rbxassetid://11821815791",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_swinehunde2",Kind="Voice",Name="Swinehunde!",Translation="Pig-dogs!",Asset="rbxassetid://11821815870",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_ehreswinehunde",Kind="Voice",Name="Ehre Swinehunde!",Translation="Pig-dogs!",Asset="rbxassetid://11821815456",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_rahahaha",Kind="Voice",Name="Rahahaha!",Translation="Rahahaha!",Asset="rbxassetid://11821815699",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_attake",Kind="Voice",Name="Attake!",Translation="Attack!",Asset="rbxassetid://11821866413",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_attake1",Kind="Voice",Name="Attake!",Translation="Attack!",Asset="rbxassetid://11821866488",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_attake2",Kind="Voice",Name="Attake! Attake!",Translation="Attack! Attack!",Asset="rbxassetid://11821866611",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_zumangriff",Kind="Voice",Name="Zum angriff!",Translation="On attack!",Asset="rbxassetid://11821866677",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_zumangriff1",Kind="Voice",Name="Zum angriff!",Translation="On attack!",Asset="rbxassetid://11821866355",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_vowarts",Kind="Voice",Name="Vowarts zum sieg!",Translation="Forwards to victory!",Asset="rbxassetid://11821906995",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_vowarts1",Kind="Voice",Name="Vowarts zum sieg!",Translation="Forwards to victory!",Asset="rbxassetid://11821907089",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_vowarts2",Kind="Voice",Name="Vowarts! Vowarts!",Translation="Forwards! Forwards!",Asset="rbxassetid://11821907133",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein/rhein_aufmeine",Kind="Voice",Name="Auf meine bruden, zum sieg!",Translation="Now my brothers, to victory!",Asset="rbxassetid://11821907046",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Rhein",LanguageGroup="Rhein"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_totall",Kind="Voice",Name="Tot all unseren feinden!",Translation="Death to all our enemies!",Asset="rbxassetid://11821948092",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_totall1",Kind="Voice",Name="Tot all unseren feinden!",Translation="Death to all our enemies!",Asset="rbxassetid://11821948040",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_aufsie",Kind="Voice",Name="Auf sie!",Translation="On them!",Asset="rbxassetid://11821948004",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_unseren",Kind="Voice",Name="Unseren feiden!",Translation="Our enemies!",Asset="rbxassetid://11821947959",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_schlagsie",Kind="Voice",Name="Schlag sie!",Translation="Destroy them!",Asset="rbxassetid://11821977014",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_schlagsie1",Kind="Voice",Name="Schlag sie nieder!",Translation="Destroy them!",Asset="rbxassetid://11821977058",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_schlagsie2",Kind="Voice",Name="Schlag sie... Schlag sie nieder!",Translation="Destroy them!",Asset="rbxassetid://11821977114",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_schlagsie3",Kind="Voice",Name="Schlagt sie macht sie fertig!",Translation="Destroy them!",Asset="rbxassetid://11821977176",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_hoorah",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://11821993511",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_hoorah1",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://11821993586",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_hoorah2",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://11821993685",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_hoorah3",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://11821993768",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_hoorahaha",Kind="Voice",Name="Hoorahahaha!",Translation="Hoorahahaha!",Asset="rbxassetid://11821993895",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_hoorahaha1",Kind="Voice",Name="Hoorahahaha!",Translation="Hoorahahaha!",Asset="rbxassetid://11821993461",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_laughter",Kind="Voice",Name="(Maniacal Laughter)",Translation="(Maniacal Laughter)",Asset="rbxassetid://11821993837",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_wirwerden",Kind="Voice",Name="Wir wereden gewinnen!",Translation="Wir wereden gewinnen!",Asset="rbxassetid://11822047439",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_wirwerden1",Kind="Voice",Name="Wir werden den sieg holen!",Translation="Wir werden den sieg holen!",Asset="rbxassetid://11822047579",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_wirwerden2",Kind="Voice",Name="Wir werden gewinnen!",Translation="Wir werden gewinnen!",Asset="rbxassetid://11822047624",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed/rheinMixed_niemandkann",Kind="Voice",Name="Niemand kann uns aufhalten!",Translation="Niemand kann uns aufhalten!",Asset="rbxassetid://11822047538",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RheinMixed",LanguageGroup="RheinMixed"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_character",Kind="Voice",Name="Character und Aufrichtigkeit!",Translation="Character and Sincerity!",Asset="rbxassetid://11822503483",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_character1",Kind="Voice",Name="Character und Aufrichtigkeit!",Translation="Character and Sincerity!",Asset="rbxassetid://11822503640",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_character2",Kind="Voice",Name="Character und Aufrichtigkeit!",Translation="Character and Sincerity!",Asset="rbxassetid://11822503681",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_character3",Kind="Voice",Name="Character und Aufrichtigkeit!",Translation="Character and Sincerity!",Asset="rbxassetid://11822503740",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_horma",Kind="Voice",Name="Hoer ma, Character und Aufrichtigkeit!",Translation="Listen, Character and Sincerity!",Asset="rbxassetid://11822503579",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkonig",Kind="Voice",Name="Fuer Koenig und Vaterland!",Translation="For King and Fatherland!",Asset="rbxassetid://11822526301",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkonig1",Kind="Voice",Name="Fuer Koenig und Vaterland!",Translation="For King and Fatherland!",Asset="rbxassetid://11822526355",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkonig2",Kind="Voice",Name="Fuer Koenig und Vaterland!",Translation="For King and Fatherland!",Asset="rbxassetid://11822526457",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkonig3",Kind="Voice",Name="Fuer Koenig und Vaterland!",Translation="For King and Fatherland!",Asset="rbxassetid://11822526627",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkonig4",Kind="Voice",Name="Fuer Koenig und Vaterland, hoer ma!",Translation="For King and Fatherland, hear me!",Asset="rbxassetid://11822526544",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkaiser",Kind="Voice",Name="Fuer Westfalen, Koenig, und Kaiser!",Translation="For Westphalia, King, and Emperor!",Asset="rbxassetid://11822541665",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkaiser1",Kind="Voice",Name="Fuer Westfalen, Koenig, und Kaiser!",Translation="For Westphalia, King, and Emperor!",Asset="rbxassetid://11822541722",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkaiser2",Kind="Voice",Name="Fuer Westfalen, Koenig, und Kaiser!",Translation="For Westphalia, King, and Emperor!",Asset="rbxassetid://11822541777",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkaiser3",Kind="Voice",Name="Fuer Westfalen, Koenig, und Kaiser!",Translation="For Westphalia, King, and Emperor!",Asset="rbxassetid://11822541822",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furkaiser4",Kind="Voice",Name="Fuer Westfalen, Koenig, und Kaiser, hoer ma!",Translation="For Westphalia, King, and Emperor, hear me!",Asset="rbxassetid://11822541857",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furjerome",Kind="Voice",Name="Fuer den Ruhm Jeromes!",Translation="For the Glory of Jerome!",Asset="rbxassetid://11822551827",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furjerome1",Kind="Voice",Name="Fuer den Ruhm Jeromes!",Translation="For the Glory of Jerome!",Asset="rbxassetid://11822551956",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furjerome2",Kind="Voice",Name="Fuer den Ruhm Jeromes!",Translation="For the Glory of Jerome!",Asset="rbxassetid://11822551915",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_furjerome3",Kind="Voice",Name="In Namen Jeromes!",Translation="In the name of Jerome!",Asset="rbxassetid://11822551867",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_destroythem",Kind="Voice",Name="Hoer ma, macht sie fertig!",Translation="Hear me, finish them off!",Asset="rbxassetid://11822570083",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_destroythem1",Kind="Voice",Name="Tot all unseren feinden, hoer ma!",Translation="Death to all our enemies, hear me!",Asset="rbxassetid://11822570195",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_destroythem2",Kind="Voice",Name="Macht sie fertig!",Translation="Finish them off!",Asset="rbxassetid://11822570252",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian/westphalian_victory",Kind="Voice",Name="Hoer ma wir werden gewinnen!",Translation="Hear me, we're going to win!",Asset="rbxassetid://11822591552",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Westphalian",LanguageGroup="Westphalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_llawen1",Kind="Voice",Name="Llawenhewch!",Translation="Rejoice!",Asset="rbxassetid://16896951058",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_llawen2",Kind="Voice",Name="Llawenhewch!",Translation="Rejoice!",Asset="rbxassetid://16896950854",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_dewch1",Kind="Voice",Name="Dewch Ymlaen Bois!",Translation="Let's go lads!",Asset="rbxassetid://16896950265",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_dewch2",Kind="Voice",Name="Dewch Ymlaen Bois!",Translation="Let's go lads!",Asset="rbxassetid://16896950603",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_gaddy1",Kind="Voice",Name="Gad i fynd!",Translation="Onwards!",Asset="rbxassetid://16896949999",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_gaddy2",Kind="Voice",Name="Gad i fynd!",Translation="Onwards!",Asset="rbxassetid://16896949751",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_huzzah1",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://16896949041",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_huzzah2",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://16896949422",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_godsave1",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://16896948511",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_godsave2",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://16896946542",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_cymru1",Kind="Voice",Name="Cymru am byth!",Translation="Wales Forever!",Asset="rbxassetid://16896948205",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_cymru2",Kind="Voice",Name="Cymru am byth!",Translation="Wales Forever!",Asset="rbxassetid://16896947392",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_rule1",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://16896947878",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale/welsh_rule2",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://16896946900",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/WelshMale",LanguageGroup="Welsh"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_forwardcom1",Kind="Voice",Name="Forward Comrades!",Translation="? ? ?",Asset="rbxassetid://12452570154",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_forwardcom2",Kind="Voice",Name="Forward Comrades!",Translation="? ? ?",Asset="rbxassetid://12452569873",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_forwardcom3",Kind="Voice",Name="Forward Comrades!",Translation="? ? ?",Asset="rbxassetid://12452569525",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_forwardcom4",Kind="Voice",Name="Forward Comrades!",Translation="? ? ?",Asset="rbxassetid://12452569017",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_hurra1",Kind="Voice",Name="Hurra!",Translation="? ? ?",Asset="rbxassetid://12467441745",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_hurra2",Kind="Voice",Name="Hurra!",Translation="? ? ?",Asset="rbxassetid://12467442588",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_hurra3",Kind="Voice",Name="Hurra!",Translation="? ? ?",Asset="rbxassetid://12467442096",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_hurra4",Kind="Voice",Name="Hurra!",Translation="? ? ?",Asset="rbxassetid://12452567759",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_tamadas1",Kind="Voice",Name="Támadás!",Translation="? ? ?",Asset="rbxassetid://12452567943",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_tamadas2",Kind="Voice",Name="Támadás!",Translation="? ? ?",Asset="rbxassetid://12452567943",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_tamadas3",Kind="Voice",Name="Támadás!",Translation="? ? ?",Asset="rbxassetid://12452567154",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_tamadas4",Kind="Voice",Name="Támadás!",Translation="? ? ?",Asset="rbxassetid://12452566780",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_tamadas5",Kind="Voice",Name="Támadás!",Translation="? ? ?",Asset="rbxassetid://12452566077",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_vess1",Kind="Voice",Name="Veszenek!",Translation="? ? ?",Asset="rbxassetid://12452565813",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_vess2",Kind="Voice",Name="Veszenek!",Translation="? ? ?",Asset="rbxassetid://12452566403",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_vess3",Kind="Voice",Name="Veszenek!",Translation="? ? ?",Asset="rbxassetid://12452565588",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_vess4",Kind="Voice",Name="Veszenek!",Translation="? ? ?",Asset="rbxassetid://12452565389",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_puz1",Kind="Voice",Name="Pusztuljanak!",Translation="? ? ?",Asset="rbxassetid://12452565193",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_puz2",Kind="Voice",Name="Pusztuljanak!",Translation="? ? ?",Asset="rbxassetid://12452564932",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_puz3",Kind="Voice",Name="Pusztuljanak!",Translation="? ? ?",Asset="rbxassetid://12452564671",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_puz4",Kind="Voice",Name="Pusztuljanak!",Translation="? ? ?",Asset="rbxassetid://12452564180",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_puz5",Kind="Voice",Name="Pusztuljanak!",Translation="? ? ?",Asset="rbxassetid://12452562778",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_nin1",Kind="Voice",Name="Nincs kegyelem!!",Translation="? ? ?",Asset="rbxassetid://12452564457",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_nin2",Kind="Voice",Name="Nincs kegyelem!!",Translation="? ? ?",Asset="rbxassetid://12452563931",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_nin3",Kind="Voice",Name="Nincs kegyelem!!",Translation="? ? ?",Asset="rbxassetid://12452563677",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_nin4",Kind="Voice",Name="Nincs kegyelem!",Translation="? ? ?",Asset="rbxassetid://12452563411",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_nin5",Kind="Voice",Name="Nincs kegyelem!",Translation="? ? ?",Asset="rbxassetid://12452563137",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_furkaiser1",Kind="Voice",Name="Für den Kaiser!",Translation="? ? ?",Asset="rbxassetid://12456459346",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_furkaiser2",Kind="Voice",Name="Für den Kaiser!",Translation="? ? ?",Asset="rbxassetid://12456459942",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_furkaiser3",Kind="Voice",Name="Für den Kaiser!",Translation="? ? ?",Asset="rbxassetid://12456460287",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_gottkaiser1",Kind="Voice",Name="Für Österreich!",Translation="? ? ?",Asset="rbxassetid://12453525874",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_gottkaiser2",Kind="Voice",Name="Für Österreich!",Translation="? ? ?",Asset="rbxassetid://12453526546",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale/hungarian_gottkaiser3",Kind="Voice",Name="Für Österreich!",Translation="? ? ?",Asset="rbxassetid://12453527013",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/HungarianMale",LanguageGroup="Hungarian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_hoorah1",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://12456455429",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_hoorah2",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://12456454239",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_hoorah3",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://12456454713",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_perish1",Kind="Voice",Name="Sie werden zugrunde gehen!",Translation="They shall perish!",Asset="rbxassetid://12456453545",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_perish2",Kind="Voice",Name="Sie werden zugrunde gehen!",Translation="They shall perish!",Asset="rbxassetid://12456454963",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_perish3",Kind="Voice",Name="Sie werden zugrunde gehen!",Translation="They shall perish!",Asset="rbxassetid://12456457076",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_nomercy1",Kind="Voice",Name="Keine gnade!",Translation="No mercy!",Asset="rbxassetid://12456454485",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_nomercy2",Kind="Voice",Name="Keine gnade!",Translation="No mercy!",Asset="rbxassetid://12456453966",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_nomercy3",Kind="Voice",Name="Keine gnade!",Translation="No mercy!",Asset="rbxassetid://12456453742",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_gottschuetze1",Kind="Voice",Name="Gott Schütze den König!",Translation="God save the King!",Asset="rbxassetid://12456455633",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_gottschuetze2",Kind="Voice",Name="Gott Schütze den König!",Translation="God save the King!",Asset="rbxassetid://12456455189",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_gottschuetze3",Kind="Voice",Name="Gott Schütze den König!",Translation="God save the King!",Asset="rbxassetid://12456456475",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_fuerkoenig1",Kind="Voice",Name="Für König und Vaterland!",Translation="For King and Fatherland!",Asset="rbxassetid://12456455864",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_fuerkoenig2",Kind="Voice",Name="Für König und Vaterland!",Translation="For King and Fatherland!",Asset="rbxassetid://12456456182",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_fuerkoenig3",Kind="Voice",Name="Für König und Vaterland!",Translation="For King and Fatherland!",Asset="rbxassetid://12456456742",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_forward1",Kind="Voice",Name="Vorwärts Kameraden!",Translation="Forwards Comrades!",Asset="rbxassetid://12456457416",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_forward2",Kind="Voice",Name="Vorwärts Kameraden!",Translation="Forwards Comrades!",Asset="rbxassetid://12456457686",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_forward3",Kind="Voice",Name="Vorwärts Kameraden!",Translation="Forwards Comrades!",Asset="rbxassetid://12456457897",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_forwardboys1",Kind="Voice",Name="Vorwärts Junges!",Translation="Forwards Boys!",Asset="rbxassetid://12456458090",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_forwardboys2",Kind="Voice",Name="Vorwärts Junges!",Translation="Forwards Boys!",Asset="rbxassetid://12456458685",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_forwardboys3",Kind="Voice",Name="Vorwärts Junges!",Translation="Forwards Boys!",Asset="rbxassetid://12456459095",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_furkaiser1",Kind="Voice",Name="Für den Kaiser!",Translation="For the Kaiser!",Asset="rbxassetid://12456459346",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_furkaiser2",Kind="Voice",Name="Für den Kaiser!",Translation="For the Kaiser!",Asset="rbxassetid://12456459942",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_furkaiser3",Kind="Voice",Name="Für den Kaiser!",Translation="For the Kaiser!",Asset="rbxassetid://12456460287",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_furvaterland1",Kind="Voice",Name="Für das Vaterland!",Translation="For the Fatherland!",Asset="rbxassetid://12456458898",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_furvaterland2",Kind="Voice",Name="Für das Vaterland!",Translation="For the Fatherland!",Asset="rbxassetid://12456459635",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_furvaterland3",Kind="Voice",Name="Für das Vaterland!",Translation="For the Fatherland!",Asset="rbxassetid://12456458338",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_attack1",Kind="Voice",Name="Attacke!",Translation="Attack!",Asset="rbxassetid://12456463239",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_attack2",Kind="Voice",Name="Attacke!",Translation="Attack!",Asset="rbxassetid://12456462882",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_attack3",Kind="Voice",Name="Attacke!",Translation="Attack!",Asset="rbxassetid://12456462646",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_destroy1",Kind="Voice",Name="Vernichtet sie!",Translation="Destroy them!",Asset="rbxassetid://12456461600",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_destroy2",Kind="Voice",Name="Vernichtet sie!",Translation="Destroy them!",Asset="rbxassetid://12456461282",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_destroy3",Kind="Voice",Name="Vernichtet sie!",Translation="Destroy them!",Asset="rbxassetid://12456461071",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_charge1",Kind="Voice",Name="Angriff!",Translation="Charge!",Asset="rbxassetid://12456462411",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_charge2",Kind="Voice",Name="Angriff!",Translation="Charge!",Asset="rbxassetid://12456462145",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_charge3",Kind="Voice",Name="Angriff!",Translation="Charge!",Asset="rbxassetid://12456461914",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_follow1",Kind="Voice",Name="Folge mir junges!",Translation="Follow me boys!",Asset="rbxassetid://12456463493",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale/german_follow2",Kind="Voice",Name="Folge mir junges!",Translation="Follow me boys!",Asset="rbxassetid://12456460848",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanMale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_atzi1",Kind="Voice",Name="Ať žije císař!",Translation="Long live the Emperor!",Asset="rbxassetid://12467217878",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_atzi2",Kind="Voice",Name="Ať žije císař!",Translation="Long live the Emperor!",Asset="rbxassetid://12467217564",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_doni1",Kind="Voice",Name="Do nich bratři!",Translation="Get them comrades!",Asset="rbxassetid://12467281870",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_doni2",Kind="Voice",Name="Do nich bratři!",Translation="Get them comrades!",Asset="rbxassetid://12467281224",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_doni3",Kind="Voice",Name="Do nich bratři!",Translation="Get them comrades!",Asset="rbxassetid://12467281589",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_rats1",Kind="Voice",Name="Zhyňte krysy!",Translation="Die you rats!",Asset="rbxassetid://12467324091",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_nikdy1",Kind="Voice",Name="Nikdy se nevzdáme!",Translation="We shall never surrender!",Asset="rbxassetid://12467365089",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_nikdy2",Kind="Voice",Name="Nikdy se nevzdáme!",Translation="We shall never surrender!",Asset="rbxassetid://12467365404",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_hura1",Kind="Voice",Name="Hüra!",Translation="Hoorah!",Asset="rbxassetid://12467441745",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_hura2",Kind="Voice",Name="Hüra!",Translation="Hoorah!",Asset="rbxassetid://12467442588",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_hura3",Kind="Voice",Name="Hüra!",Translation="Hoorah!",Asset="rbxassetid://12467442096",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_zab1",Kind="Voice",Name="Zabte je všechny!",Translation="Kill them all!",Asset="rbxassetid://12467490194",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_zab2",Kind="Voice",Name="Zabte je všechny!",Translation="Kill them all!",Asset="rbxassetid://12467489710",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_furkaiser1",Kind="Voice",Name="Für den Kaiser!",Translation="? ? ?",Asset="rbxassetid://12456459346",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_furkaiser2",Kind="Voice",Name="Für den Kaiser!",Translation="? ? ?",Asset="rbxassetid://12456459942",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_furkaiser3",Kind="Voice",Name="Für den Kaiser!",Translation="? ? ?",Asset="rbxassetid://12456460287",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_ost1",Kind="Voice",Name="Za Rakousko!",Translation="? ? ?",Asset="rbxassetid://12497673166",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale/czech_ost2",Kind="Voice",Name="Za Rakousko!",Translation="? ? ?",Asset="rbxassetid://12497672822",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CzechMale",LanguageGroup="Czech"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_nosey1",Kind="Voice",Name="Hurrah For Old Nosey!",Translation="Hurrah For Old Nosey!",Asset="rbxassetid://12667893919",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_nosey2",Kind="Voice",Name="Hurrah For Old Nosey!",Translation="Hurrah For Old Nosey!",Asset="rbxassetid://12667894149",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_kingandcountry1",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://12667910077",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_kingandcountry2",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://12667909598",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_kingandcountry3",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://12667909051",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_britannia1",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://12670007978",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_britannia2",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://12670007528",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_scotland1",Kind="Voice",Name="Scotland Forever!",Translation="Scotland Forever!",Asset="rbxassetid://6754847125",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_scotland2",Kind="Voice",Name="Scotland Forever!",Translation="Scotland Forever!",Asset="rbxassetid://12667972348",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_scotland3",Kind="Voice",Name="Scotland Forever!",Translation="Scotland Forever!",Asset="rbxassetid://12667972613",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_huzzah1",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://12668027785",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_huzzah2",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://12668027472",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_bydand1",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://12668066896",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_bydand2",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://12668066655",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_bydand3",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://12668066367",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_sons1",Kind="Voice",Name="Sons of the Hounds!",Translation="Sons of the Hounds!",Asset="rbxassetid://12668095513",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_sons2",Kind="Voice",Name="Sons of the Hounds!",Translation="Sons of the Hounds!",Asset="rbxassetid://12668095907",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_god1",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://12668125176",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_god2",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://12668124803",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale/scottish_god3",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://12668125020",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ScottishMale",LanguageGroup="Scottish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_medgud1",Kind="Voice",Name="Med Gud och segerrika vapen!",Translation="With God and Victorious arms!",Asset="rbxassetid://12822270605",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_medgud2",Kind="Voice",Name="Med Gud och segerrika vapen!",Translation="With God and Victorious arms!",Asset="rbxassetid://12822270086",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_medgud3",Kind="Voice",Name="Med Gud och segerrika vapen!",Translation="With God and Victorious arms!",Asset="rbxassetid://12822269616",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_medgud4",Kind="Voice",Name="Med Gud och segerrika vapen!",Translation="With God and Victorious arms!",Asset="rbxassetid://12822269185",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_medgud5",Kind="Voice",Name="Med Gud och segerrika vapen!",Translation="With God and Victorious arms!",Asset="rbxassetid://12822268553",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hurra1",Kind="Voice",Name="Hurra! Hurra!",Translation="Hurra! Hurra!",Asset="rbxassetid://12822289759",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hurra2",Kind="Voice",Name="Hurra! Hurra!",Translation="Hurra! Hurra!",Asset="rbxassetid://12822289342",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hurra3",Kind="Voice",Name="Hurra! Hurra!",Translation="Hurra! Hurra!",Asset="rbxassetid://12822288983",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hurra4",Kind="Voice",Name="Hurra! Hurra!",Translation="Hurra! Hurra!",Asset="rbxassetid://12822288726",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hurra5",Kind="Voice",Name="Hurra! Hurra!",Translation="Hurra! Hurra!",Asset="rbxassetid://12822287983",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hacka1",Kind="Voice",Name="Hacka på!",Translation="Fight on!",Asset="rbxassetid://12822307047",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hacka2",Kind="Voice",Name="Hacka på!",Translation="Fight on!",Asset="rbxassetid://12822306525",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hacka3",Kind="Voice",Name="Hacka på!",Translation="Fight on!",Asset="rbxassetid://12822306057",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hacka4",Kind="Voice",Name="Hacka på!",Translation="Fight on!",Asset="rbxassetid://12822305590",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_hacka5",Kind="Voice",Name="Hacka på!",Translation="Fight on!",Asset="rbxassetid://12822304685",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_bevare1",Kind="Voice",Name="Gud bevare konungen!",Translation="God Protect the King!",Asset="rbxassetid://12822449665",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_bevare2",Kind="Voice",Name="Gud bevare konungen!",Translation="God Protect the King!",Asset="rbxassetid://12822449345",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_bevare3",Kind="Voice",Name="Gud bevare konungen!",Translation="God Protect the King!",Asset="rbxassetid://12822449345",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_bevare4",Kind="Voice",Name="Gud bevare konungen!",Translation="God Protect the King!",Asset="rbxassetid://12822448472",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_gudar1",Kind="Voice",Name="Gud är med oss!",Translation="God is with Us!",Asset="rbxassetid://12822495021",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_gudar2",Kind="Voice",Name="Gud är med oss!",Translation="God is with Us!",Asset="rbxassetid://12822495607",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_gudar3",Kind="Voice",Name="Gud är med oss!",Translation="God is with Us!",Asset="rbxassetid://12822496239",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_gudar4",Kind="Voice",Name="Gud är med oss!",Translation="God is with Us!",Asset="rbxassetid://12822496750",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_forgud1",Kind="Voice",Name="För gud och fäderneslandet!",Translation="For God and Fatherland!",Asset="rbxassetid://12822522125",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_forgud2",Kind="Voice",Name="För gud och fäderneslandet!",Translation="For God and Fatherland!",Asset="rbxassetid://12822522770",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_forgud3",Kind="Voice",Name="För gud och fäderneslandet!",Translation="For God and Fatherland!",Asset="rbxassetid://12822523120",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_forgud4",Kind="Voice",Name="För gud och fäderneslandet!",Translation="For God and Fatherland!",Asset="rbxassetid://12822523416",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_forgud5",Kind="Voice",Name="För gud och fäderneslandet!",Translation="For God and Fatherland!",Asset="rbxassetid://12822523794",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_forf1",Kind="Voice",Name="För Fäderneslandet, gå på, Hurra!",Translation="For the Fatherland, onwards, Hurrah!",Asset="rbxassetid://12822587146",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_forf2",Kind="Voice",Name="För Fäderneslandet, gå på, Hurra!",Translation="For the Fatherland, onwards, Hurrah!",Asset="rbxassetid://12822587635",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_forf3",Kind="Voice",Name="För Fäderneslandet, gå på, Hurra!",Translation="For the Fatherland, onwards, Hurrah!",Asset="rbxassetid://12822587968",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_forf4",Kind="Voice",Name="För Fäderneslandet, gå på, Hurra!",Translation="For the Fatherland, onwards, Hurrah!",Asset="rbxassetid://12822588411",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_arvet1",Kind="Voice",Name="Arvet förpliktar!",Translation="The legacy demands it!",Asset="rbxassetid://12822630410",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_arvet2",Kind="Voice",Name="Arvet förpliktar!",Translation="The legacy demands it!",Asset="rbxassetid://12822629928",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_arvet3",Kind="Voice",Name="Arvet förpliktar!",Translation="The legacy demands it!",Asset="rbxassetid://12822629503",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_arvet4",Kind="Voice",Name="Arvet förpliktar!",Translation="The legacy demands it!",Asset="rbxassetid://12822629032",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale/swedish_arvet5",Kind="Voice",Name="Arvet förpliktar!",Translation="The legacy demands it!",Asset="rbxassetid://12822628474",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SwedishMale",LanguageGroup="Swedish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_charge1",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://14588633875",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_charge2",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://14588633492",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_condemn1",Kind="Voice",Name="The Condemned! ",Translation="The Condemned!",Asset="rbxassetid://14588560808",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_condemn2",Kind="Voice",Name="The Condemned! ",Translation="The Condemned!",Asset="rbxassetid://14588560158",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_condemn3",Kind="Voice",Name="The Condemned! ",Translation="The Condemned!",Asset="rbxassetid://14588560565",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_runyadogs1",Kind="Voice",Name="Run ya Dogs!",Translation="Run ya Dogs!",Asset="rbxassetid://14588579246",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_rule1",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://14588639081",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_rule2",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://14588638791",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_huzzah1",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://14588613739",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_huzzah2",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://14588614034",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_god1",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://14588628978",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_god2",Kind="Voice",Name="God Save the King!",Translation="God Save the King!",Asset="rbxassetid://14588628448",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_king1",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://14588618352",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale/australian_king2",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://14588618037",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AustralianMale",LanguageGroup="Australian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesCowboy/naples_yeehaw",Kind="Voice",Name="Yeehaw!",Translation="Yeehaw!",Asset="rbxassetid://12852132826",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesCowboy",LanguageGroup="NaplesCowboy"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesCowboy/naples_cattle",Kind="Voice",Name="Them Cattle Rustlers!",Translation="Them Cattle Rustlers!",Asset="rbxassetid://12852132801",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesCowboy",LanguageGroup="NaplesCowboy"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesCowboy/naples_filthy",Kind="Voice",Name="Filthy Shwine!",Translation="Filthy Swhine!",Asset="rbxassetid://12852132761",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesCowboy",LanguageGroup="NaplesCowboy"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesCowboy/naples_lead",Kind="Voice",Name="Im gonna pump you full of lead!",Translation="Im gonna pump you full of lead!",Asset="rbxassetid://12852132727",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NaplesCowboy",LanguageGroup="NaplesCowboy"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_perish1",Kind="Voice",Name="They shall perish!",Translation="They shall perish!",Asset="rbxassetid://13154852883",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_perish2",Kind="Voice",Name="They shall perish!",Translation="They shall perish!",Asset="rbxassetid://13154853525",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_perish3",Kind="Voice",Name="They shall perish!",Translation="They shall perish!",Asset="rbxassetid://13154853898",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_mercy1",Kind="Voice",Name="No mercy!",Translation="No mercy!",Asset="rbxassetid://13154822821",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_mercy2",Kind="Voice",Name="No mercy!",Translation="No mercy!",Asset="rbxassetid://13154822422",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_mercy3",Kind="Voice",Name="No mercy!",Translation="No mercy!",Asset="rbxassetid://13154821762",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_horrah1",Kind="Voice",Name="Horrah!",Translation="Horrah!",Asset="rbxassetid://13154805278",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_horrah2",Kind="Voice",Name="Horrah!",Translation="Horrah!",Asset="rbxassetid://13154805602",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_horrah3",Kind="Voice",Name="Horrah!",Translation="Horrah!",Asset="rbxassetid://13154804804",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Forwardcomrades1",Kind="Voice",Name="Forward comrades!",Translation="Forward comrades!",Asset="rbxassetid://13154790198",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Forwardcomrades2",Kind="Voice",Name="Forward comrades!",Translation="Forward comrades!",Asset="rbxassetid://13154790543",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Forwardcomrades3",Kind="Voice",Name="Forward comrades!",Translation="Forward comrades!",Asset="rbxassetid://13154789811",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Forwardboys1",Kind="Voice",Name="Forward boys!",Translation="Forward boys!",Asset="rbxassetid://14134181687",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Forwardboys2",Kind="Voice",Name="Forward boys!",Translation="Forward boys!",Asset="rbxassetid://14134181278",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Fatherland1",Kind="Voice",Name="For the Fatherland!",Translation="For the Fatherland!",Asset="rbxassetid://13154768665",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Fatherland2",Kind="Voice",Name="For the Fatherland!",Translation="For the Fatherland!",Asset="rbxassetid://13154768233",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Fatherland3",Kind="Voice",Name="For the Fatherland!",Translation="For the Fatherland!",Asset="rbxassetid://13154767634",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_ForTheEmperor1",Kind="Voice",Name="For the Emperor!",Translation="For the Emperor!",Asset="rbxassetid://13154747244",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_ForTheEmperor2",Kind="Voice",Name="For the Emperor!",Translation="For the Emperor!",Asset="rbxassetid://13154747550",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_ForTheEmperor3",Kind="Voice",Name="For the Emperor!",Translation="For the Emperor!",Asset="rbxassetid://13154746795",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Followmeboys1",Kind="Voice",Name="Follow me boys!",Translation="Follow me boys!",Asset="rbxassetid://13154723425",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Followmeboys2",Kind="Voice",Name="Follow me boys!",Translation="Follow me boys!",Asset="rbxassetid://13154723957",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Followmeboys3",Kind="Voice",Name="Follow me boys!",Translation="Follow me boys!",Asset="rbxassetid://13154724273",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Destroythem2",Kind="Voice",Name="Destroy them!",Translation="Destroy them!",Asset="rbxassetid://14134203421",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Destroythem3",Kind="Voice",Name="Destroy them!",Translation="Destroy them!",Asset="rbxassetid://14134203122",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Charge1",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://14134120555",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Charge2",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://14134120377",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Attack1",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://13154668743",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Attack2",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://13154669303",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale/Croatian_Attack3",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://13154669695",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/CroatianMale",LanguageGroup="Croatian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FunnyChants/press_two",Kind="Voice",Name="Press two!",Translation="Press two!",Asset="rbxassetid://6594703222",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FunnyChants",LanguageGroup="FunnyChants"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SiamMale/siam_destroy",Kind="Voice",Name="We have to destroy them, destroy them!",Translation="We have to destroy them, destroy them!",Asset="rbxassetid://7296598704",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SiamMale",LanguageGroup="Siam"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SiamMale/siam_best",Kind="Voice",Name="Is this the best you can do?",Translation="Is this the best you can do?",Asset="rbxassetid://7296594675",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SiamMale",LanguageGroup="Siam"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SiamMale/siam_if",Kind="Voice",Name="If you knew who I am you would shiver!",Translation="If you knew who I am you would shiver!",Asset="rbxassetid://7296583593",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SiamMale",LanguageGroup="Siam"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_Dracu1",Kind="Voice",Name="Sa îi trimitem la dracu!",Translation="Send them to hell!",Asset="rbxassetid://14588248044",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_Dracu2",Kind="Voice",Name="Sa ii invârtim prin flăcări, în iad sa îi trimitem!",Translation="Let's turn them through the flames, send them to hell!",Asset="rbxassetid://14588247719",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_Dracu3",Kind="Voice",Name="SA ÎI TRIMITEM LA DRACU!",Translation="Send them to hell!",Asset="rbxassetid://14588247245",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_Exista1",Kind="Voice",Name="Există o singură cale, Înainte!",Translation="There is only one way, forwards!",Asset="rbxassetid://14588295235",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_Exista2",Kind="Voice",Name="Există o singură cale, Înainte!",Translation="There is only one way, forwards!",Asset="rbxassetid://14588295004",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_Exista3",Kind="Voice",Name="Există o singură cale, Înainte!",Translation="There is only one way, forwards!",Asset="rbxassetid://14588294644",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_NuCedati1",Kind="Voice",Name="Nu cedați!",Translation="Dont give in!",Asset="rbxassetid://14588294644",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_NuCedati2",Kind="Voice",Name="NU CEDAȚI FLĂCĂII!",Translation="Dont give in boys!",Asset="rbxassetid://14588294644",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_NuCedati3",Kind="Voice",Name="Nu cedați!",Translation="Dont give in!",Asset="rbxassetid://14588294644",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_Ura1",Kind="Voice",Name="Uraaa!",Translation="Uraaa!",Asset="rbxassetid://14588345324",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_Ura2",Kind="Voice",Name="Uraaa!",Translation="Uraaa!",Asset="rbxassetid://14588345089",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_With1",Kind="Voice",Name="Cu foc și cu sabie, apărăm gloria noastră!",Translation="With fire and sword, we defend our glory!",Asset="rbxassetid://14588377059",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_With2",Kind="Voice",Name="With flames and steel, our glory resounds!",Translation="Cu flăcări si oțel, gloria noastră răsună!",Asset="rbxassetid://14588376592",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale/Romanian_With3",Kind="Voice",Name="Cu foc și cu sabie, apărăm gloria noastră!",Translation="With fire and sword, we defend our glory!",Asset="rbxassetid://14588377305",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianMale",LanguageGroup="Romanian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_kaiser",Kind="Voice",Name="Dlya Kayzera!",Translation="For the Kasier!",Asset="rbxassetid://92469116930846",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_kaiser2",Kind="Voice",Name="Dlya Kayzera!",Translation="For the Kasier!",Asset="rbxassetid://138520619143188",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_kaiser3",Kind="Voice",Name="Dlya Kayzera!",Translation="For the Kasier!",Asset="rbxassetid://83554973691675",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_fatherland",Kind="Voice",Name="Za Imperyu!",Translation="For the empire!",Asset="rbxassetid://126390496059358",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_fatherland2",Kind="Voice",Name="Za Imperyu!",Translation="For the empire!",Asset="rbxassetid://96356998322148",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_fatherland3",Kind="Voice",Name="Za Imperyu!",Translation="For the empire!",Asset="rbxassetid://127652548940514",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_fatherland4",Kind="Voice",Name="Für Osterayk!",Translation="For the empire!",Asset="rbxassetid://105762903413139",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_fatherland5",Kind="Voice",Name="Für Osterayk!",Translation="For the empire!",Asset="rbxassetid://137335036664856",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_fatherland6",Kind="Voice",Name="Für Osterayk!",Translation="For the empire!",Asset="rbxassetid://98228821411991",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_ura",Kind="Voice",Name="Uraaa!",Translation="Uraaa!",Asset="rbxassetid://127427261639294",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_ura2",Kind="Voice",Name="Uraaa!",Translation="Uraaa!",Asset="rbxassetid://101052032455378",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_ura3",Kind="Voice",Name="Uraaa!",Translation="Uraaa!",Asset="rbxassetid://86105569826019",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_forwards",Kind="Voice",Name="Do boyu!",Translation="Forward!",Asset="rbxassetid://122463365191922",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_forwards2",Kind="Voice",Name="Do boyu!",Translation="Forward!",Asset="rbxassetid://134696518447994",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_forwards3",Kind="Voice",Name="Do boyu!",Translation="Forward!",Asset="rbxassetid://115201209458744",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_followme",Kind="Voice",Name="Sliduy Za Mnoyou!",Translation="Follow me boys!",Asset="rbxassetid://75401302562339",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_followme2",Kind="Voice",Name="Sliduy Za Mnoyou!",Translation="Follow me boys!",Asset="rbxassetid://123601869294356",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_followme3",Kind="Voice",Name="Sliduy Za Mnoyou!",Translation="Follow me boys!",Asset="rbxassetid://79603621419068",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_followme4",Kind="Voice",Name="Sliduy Za Mnoyou!",Translation="Follow me boys!",Asset="rbxassetid://85945496630126",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_crush",Kind="Voice",Name="Vidchuyte Smak Stali!",Translation="Crush them!",Asset="rbxassetid://106797619124161",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_crush2",Kind="Voice",Name="Vidchuyte Smak Stali!",Translation="Crush them!",Asset="rbxassetid://90654276376326",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_crush3",Kind="Voice",Name="Vidchuyte Smak Stali!",Translation="Crush them!",Asset="rbxassetid://94514011279049",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_galicia",Kind="Voice",Name="Za Galichinu!",Translation="For Galicia!",Asset="rbxassetid://76612673522795",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_galicia2",Kind="Voice",Name="Za Galichinu!",Translation="For Galicia!",Asset="rbxassetid://78322242060052",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_galicia3",Kind="Voice",Name="Za Galichinu!",Translation="For Galicia!",Asset="rbxassetid://82376807308180",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_glory",Kind="Voice",Name="Slava, Slava, Slava!",Translation="Glory, Glory, Glory!",Asset="rbxassetid://125196082127633",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_glory2",Kind="Voice",Name="Slava, Slava, Slava!",Translation="Glory, Glory, Glory!",Asset="rbxassetid://126772683448906",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_glory3",Kind="Voice",Name="Slava, Slava, Slava!",Translation="Glory, Glory, Glory!",Asset="rbxassetid://87258720164715",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_glory4",Kind="Voice",Name="Slava!",Translation="Glory!",Asset="rbxassetid://107910646647415",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_glory5",Kind="Voice",Name="Slava!",Translation="Glory!",Asset="rbxassetid://121515128817010",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_glory6",Kind="Voice",Name="Slava!",Translation="Glory!",Asset="rbxassetid://85960441530504",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_god",Kind="Voice",Name="Bog Sered Nas!",Translation="God is with us!",Asset="rbxassetid://103851767389212",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_god2",Kind="Voice",Name="Bog Sered Nas!",Translation="God is with us!",Asset="rbxassetid://136707028242891",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_god3",Kind="Voice",Name="Bog Sered Nas!",Translation="God is with us!",Asset="rbxassetid://87967815302622",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_god4",Kind="Voice",Name="Bozhe, Blagoslovi Nas!",Translation="God is with us!",Asset="rbxassetid://107465578149100",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_god5",Kind="Voice",Name="Bozhe, Blagoslovi Nas!",Translation="God is with us!",Asset="rbxassetid://86189370856828",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_god6",Kind="Voice",Name="Bozhe, Blagoslovi Nas!",Translation="God is with us!",Asset="rbxassetid://98203434648922",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_stand",Kind="Voice",Name="Do peremoghi abo do smerti!",Translation="Stand till death!",Asset="rbxassetid://121324070257325",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_stand2",Kind="Voice",Name="Stoyti Do Smerti!",Translation="Stand till death!",Asset="rbxassetid://128223864479336",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_stand3",Kind="Voice",Name="Stoyti Do Smerti!",Translation="Stand till death!",Asset="rbxassetid://90577122947776",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_nofear",Kind="Voice",Name="Bez Strakhu!",Translation="No fear!",Asset="rbxassetid://126805142704153",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_nofear2",Kind="Voice",Name="Bez Strakhu!",Translation="No fear!",Asset="rbxassetid://88615945739455",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale/galician_nofear3",Kind="Voice",Name="Bez Strakhu!",Translation="No fear!",Asset="rbxassetid://92126379184828",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GalicianMale",LanguageGroup="Galician"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_charge1",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://9889748353",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_charge2",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://9889749547",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_rule1",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://9889763690",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_rule2",Kind="Voice",Name="Rule Britannia!",Translation="Rule Britannia!",Asset="rbxassetid://9889764517",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_king1",Kind="Voice",Name="God save the King!",Translation="God save the King!",Asset="rbxassetid://9889756353",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_king2",Kind="Voice",Name="God save the King!",Translation="God save the King!",Asset="rbxassetid://9889757932",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_huzzah1",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://9889759641",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_huzzah2",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://9889760652",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_country1",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://9889754448",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_country2",Kind="Voice",Name="For King and Country!",Translation="For King and Country!",Asset="rbxassetid://9889755467",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_nosey1",Kind="Voice",Name="Hurrah for old Nosey!",Translation="Hurrah for old Nosey!",Asset="rbxassetid://9889762035",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/brit_nosey2",Kind="Voice",Name="Hurrah for old Nosey!",Translation="Hurrah for old Nosey!",Asset="rbxassetid://9889762962",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_scot",Kind="Voice",Name="Scotland forever!",Translation="Scotland forever!",Asset="rbxassetid://11822640386",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_scot1",Kind="Voice",Name="Scotland forever!",Translation="Scotland forever!",Asset="rbxassetid://11822640546",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_scot2",Kind="Voice",Name="Scotland forever!",Translation="Scotland forever!",Asset="rbxassetid://11822640648",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_scot3",Kind="Voice",Name="Scotland forever!",Translation="Scotland forever!",Asset="rbxassetid://11822640810",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_scot4",Kind="Voice",Name="Scotland forever!",Translation="Scotland forever!",Asset="rbxassetid://11822641130",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_bydand",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://11822640898",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_bydand1",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://11822640959",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_bydand2",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://11822641023",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_bydand3",Kind="Voice",Name="Bydand!",Translation="Bydand!",Asset="rbxassetid://11822641071",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_hound",Kind="Voice",Name="Sons of the Hounds! Come here and get flesh!",Translation="Sons of the Hounds! Come here and get flesh!",Asset="rbxassetid://11822640232",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_hound1",Kind="Voice",Name="Sons of the Hounds! Come here and get flesh!",Translation="Sons of the Hounds! Come here and get flesh!",Asset="rbxassetid://11822640289",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_hound2",Kind="Voice",Name="Sons of the Hounds! Come here and get flesh!",Translation="Sons of the Hounds! Come here and get flesh!",Asset="rbxassetid://11822640431",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_hound3",Kind="Voice",Name="Sons of the Hounds! Come here and get flesh!",Translation="Sons of the Hounds! Come here and get flesh!",Asset="rbxassetid://11822640476",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/scot_hound4",Kind="Voice",Name="Sons of the Hounds! Come here and get flesh!",Translation="Sons of the Hounds! Come here and get flesh!",Asset="rbxassetid://11822640763",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/guard_onwards",Kind="Voice",Name="Make Way for the King's Guard!",Translation="Make Way for the King's Guard!",Asset="rbxassetid://12670286456",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale/guard_onwards1",Kind="Voice",Name="Make Way for the King's Guard!",Translation="Make Way for the King's Guard!",Asset="rbxassetid://12670286172",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishMale",LanguageGroup="British"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_wetake1",Kind="Voice",Name="We Take What's Ours!",Translation="We Take What's Ours!",Asset="rbxassetid://16963584141",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_wetake2",Kind="Voice",Name="We Take What's Ours!",Translation="We Take What's Ours!",Asset="rbxassetid://16963583875",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_shiver1",Kind="Voice",Name="Shiver me Timbers!",Translation="I am scared!",Asset="rbxassetid://16963584382",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_shiver2",Kind="Voice",Name="Shiver me Timbers!",Translation="You don't scare me!",Asset="rbxassetid://16963585882",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_nokings1",Kind="Voice",Name="No Kings, No Crowns!",Translation="No Kings, No Crowns!",Asset="rbxassetid://16963584664",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_nokings2",Kind="Voice",Name="No Kings, No Crowns!",Translation="No Kings, No Crowns!",Asset="rbxassetid://16963585160",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_warcry1",Kind="Voice",Name="Yo-Ho!",Translation="Yo-Ho!",Asset="rbxassetid://16963584927",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_warcry2",Kind="Voice",Name="Ahoy!",Translation="Ahoy me mateys!",Asset="rbxassetid://16963586327",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_warcry3",Kind="Voice",Name="Ahoy!",Translation="Ahoy me mateys!",Asset="rbxassetid://16963586842",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_grog1",Kind="Voice",Name="Bring me the grog!",Translation="Bring me the grog!",Asset="rbxassetid://16963586655",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_grog2",Kind="Voice",Name="Where be the grog!",Translation="Where be the grog!",Asset="rbxassetid://16963587120",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_davyjones1",Kind="Voice",Name="To Davy Jones With 'Em!",Translation="To Davy Jones With 'Em!",Asset="rbxassetid://16963586155",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_davyjones2",Kind="Voice",Name="To Davy Jones With 'Em!",Translation="To Davy Jones With 'Em!",Asset="rbxassetid://16963586484",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_hoist1",Kind="Voice",Name="Hoist the Colours!",Translation="Hoist the Colours!",Asset="rbxassetid://16963585699",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale/pirate_hoist2",Kind="Voice",Name="Hoist the Colours!",Translation="Hoist the Colours!",Asset="rbxassetid://16963586025",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/PirateMale",LanguageGroup="Pirate"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_perish1",Kind="Voice",Name="They shall perish!",Translation="They shall perish!",Asset="rbxassetid://10216005906",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_perish2",Kind="Voice",Name="They shall perish!",Translation="They shall perish!",Asset="rbxassetid://10216005310",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_perish3",Kind="Voice",Name="They shall perish!",Translation="They shall perish!",Asset="rbxassetid://10216004484",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_mercy1",Kind="Voice",Name="No mercy!",Translation="No mercy!",Asset="rbxassetid://10216003824",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_mercy2",Kind="Voice",Name="No mercy!",Translation="No mercy!",Asset="rbxassetid://10216003090",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_mercy3",Kind="Voice",Name="No mercy!",Translation="No mercy!",Asset="rbxassetid://10216002274",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_horrah1",Kind="Voice",Name="Horrah!",Translation="Horrah!",Asset="rbxassetid://10215998359",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_horrah2",Kind="Voice",Name="Horrah!",Translation="Horrah!",Asset="rbxassetid://10215998916",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_horrah3",Kind="Voice",Name="Horrah!",Translation="Horrah!",Asset="rbxassetid://10215999761",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Forwardcomrades1",Kind="Voice",Name="Forward comrades!",Translation="Forward comrades!",Asset="rbxassetid://10215997449",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Forwardcomrades2",Kind="Voice",Name="Forward comrades!",Translation="Forward comrades!",Asset="rbxassetid://10215996692",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Forwardcomrades3",Kind="Voice",Name="Forward comrades!",Translation="Forward comrades!",Asset="rbxassetid://10215995705",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Forwardboys1",Kind="Voice",Name="Forward boys!",Translation="Forward boys!",Asset="rbxassetid://10215995021",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Forwardboys2",Kind="Voice",Name="Forward boys!",Translation="Forward boys!",Asset="rbxassetid://10215994364",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Forwardboys3",Kind="Voice",Name="Forward boys!",Translation="Forward boys!",Asset="rbxassetid://10215993562",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Fatherland1",Kind="Voice",Name="For the Fatherland!",Translation="For the Fatherland!",Asset="rbxassetid://10215992913",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Fatherland2",Kind="Voice",Name="For the Fatherland!",Translation="For the Fatherland!",Asset="rbxassetid://10215992359",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Fatherland3",Kind="Voice",Name="For the Fatherland!",Translation="For the Fatherland!",Asset="rbxassetid://10215991754",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Followmeboys1",Kind="Voice",Name="Follow me boys!",Translation="Follow me boys!",Asset="rbxassetid://10215986391",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Followmeboys2",Kind="Voice",Name="Follow me boys!",Translation="Follow me boys!",Asset="rbxassetid://10215988196",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Destroythem1",Kind="Voice",Name="Destroy them!",Translation="Destroy them!",Asset="rbxassetid://10215983971",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Destroythem2",Kind="Voice",Name="Destroy them!",Translation="Destroy them!",Asset="rbxassetid://10215983102",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Destroythem3",Kind="Voice",Name="Destroy them!",Translation="Destroy them!",Asset="rbxassetid://10215981799",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Charge1",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://10215974031",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Charge2",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://10215973158",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Charge3",Kind="Voice",Name="Charge!",Translation="Charge!",Asset="rbxassetid://10215972347",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Attack1",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://10215969732",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Attack2",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://10215970924",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_Attack3",Kind="Voice",Name="Attack!",Translation="Attack!",Asset="rbxassetid://10215971569",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_FurKoenig",Kind="Voice",Name="Fuer Koenig und Vaterland!",Translation="For King and Fatherland!",Asset="rbxassetid://11822678804",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_FurKoenig1",Kind="Voice",Name="Fuer Koenig und Vaterland!",Translation="Fuer Koenig und Vaterland!",Asset="rbxassetid://11822679000",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_FurKoenig2",Kind="Voice",Name="Fuer Koenig und Vaterland!",Translation="For King and Fatherland!",Asset="rbxassetid://11822679068",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_GottSchuetze",Kind="Voice",Name="Gott Schuetze den Koenig!",Translation="God Save the King!",Asset="rbxassetid://11822678846",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_GottSchuetze1",Kind="Voice",Name="Gott Schuetze den Koenig!",Translation="God Save the King!",Asset="rbxassetid://11822678912",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale/BritishGerman_GottSchuetze2",Kind="Voice",Name="Gott Schuetze den Koenig!",Translation="God Save the King!",Asset="rbxassetid://11822679216",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/BritishGermanMale",LanguageGroup="BritishGerman"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_beybusurman1",Kind="Voice",Name="Bey Busurman!",Translation="Crush Them!",Asset="rbxassetid://17622653435",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_beybusurman2",Kind="Voice",Name="Bey Busurman!",Translation="Crush Them!",Asset="rbxassetid://17622655743",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_beybusurman3",Kind="Voice",Name="Bey Busurman!",Translation="Crush Them!",Asset="rbxassetid://17622658463",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_hurra1",Kind="Voice",Name="Hurra!",Translation="Ura!",Asset="rbxassetid://17622678220",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_hurra2",Kind="Voice",Name="Hurra!",Translation="Ura!",Asset="rbxassetid://17622682124",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_hurra3",Kind="Voice",Name="Hurra!",Translation="Ura!",Asset="rbxassetid://17622688547",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_keiseri1",Kind="Voice",Name="Keiseri Aleksanderi eest!",Translation="For Emperor Alexander!",Asset="rbxassetid://17622700350",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_keiseri2",Kind="Voice",Name="Keiseri Aleksanderi eest!",Translation="For Emperor Alexander!",Asset="rbxassetid://17622718296",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_keiseri3",Kind="Voice",Name="Keiseri Aleksanderi eest!",Translation="For Emperor Alexander!",Asset="rbxassetid://17622720348",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_nohh1",Kind="Voice",Name="Noh, tule lähemale, sa tühi argpüks!",Translation="Well, Come closer you puny cowards!",Asset="rbxassetid://17622734283",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_nohh2",Kind="Voice",Name="Noh, tule lähemale, sa tühi argpüks!",Translation="Well, Come closer you puny cowards!",Asset="rbxassetid://17622736701",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_nohh3",Kind="Voice",Name="Noh, tule lähemale, sa tühi argpüks!",Translation="Well, Come closer you puny cowards!",Asset="rbxassetid://17622739490",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_ryndame1",Kind="Voice",Name="Rünndame neid!",Translation="Attack them!",Asset="rbxassetid://17622746962",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_ryndame2",Kind="Voice",Name="Rünndame neid!",Translation="Attack them!",Asset="rbxassetid://17622749316",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_ryndame3",Kind="Voice",Name="Rünndame neid!",Translation="Attack them!",Asset="rbxassetid://17622761310",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_snamibog1",Kind="Voice",Name="S'nami bog!",Translation="God is with us!",Asset="rbxassetid://17622768894",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_snamibog2",Kind="Voice",Name="S'nami bog!",Translation="God is with us!",Asset="rbxassetid://17622771999",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_snamibog3",Kind="Voice",Name="S'nami bog!",Translation="God is with us!",Asset="rbxassetid://17622777888",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_slavsya1",Kind="Voice",Name="Slavsya Otechestvo!",Translation="Glory to the Fatherland!",Asset="rbxassetid://17622791497",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_slavsya2",Kind="Voice",Name="Slavsya Otechestvo!",Translation="Glory to the Fatherland!",Asset="rbxassetid://17622794707",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_slavsya3",Kind="Voice",Name="Slavsya Otechestvo!",Translation="Glory to the Fatherland!",Asset="rbxassetid://17622796788",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_suveraan1",Kind="Voice",Name="Suverääni eest!",Translation="For the Emperor!",Asset="rbxassetid://17622806740",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_suveraan2",Kind="Voice",Name="Suverääni eest!",Translation="For the Emperor!",Asset="rbxassetid://17622809164",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_suveraan3",Kind="Voice",Name="Suverääni eest!",Translation="For the Emperor!",Asset="rbxassetid://17622811294",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_varastadatappa1",Kind="Voice",Name="Varastada! Tappa!",Translation="Kill! Steal!",Asset="rbxassetid://17622825089",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_varastadatappa2",Kind="Voice",Name="Varastada! Tappa!",Translation="Kill! Steal!",Asset="rbxassetid://17622829685",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale/esto_varastadatappa3",Kind="Voice",Name="Varastada! Tappa!",Translation="Kill! Steal!",Asset="rbxassetid://17622834047",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/EstonianMale",LanguageGroup="Estonian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_vasha1",Kind="Voice",Name="Vasha!",Translation="Ura!",Asset="rbxassetid://17622490935",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_vasha2",Kind="Voice",Name="Vasha!",Translation="Ura!",Asset="rbxassetid://17622494037",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_vasha3",Kind="Voice",Name="Vasha!",Translation="Ura!",Asset="rbxassetid://17622496534",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_didebasamshoblos1",Kind="Voice",Name="Dideba Samshobolos!",Translation="Glory to the Fatherland!",Asset="rbxassetid://17622458420",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_didebasamshoblos2",Kind="Voice",Name="Dideba Samshobolos!",Translation="Glory to the Fatherland!",Asset="rbxassetid://17622474601",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_didebasamshoblos3",Kind="Voice",Name="Dideba Samshobolos!",Translation="Glory to the Fatherland!",Asset="rbxassetid://17622484244",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_tyviisgamoyenebasisuleleabaionetissauketeso1",Kind="Voice",Name="Tyviis Gamoyeneba Sisulelea, Baionetis Ki Sauketeso!",Translation="Bullets are foolish, the Bayonet is better!",Asset="rbxassetid://17622514492",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_tyviisgamoyenebasisuleleabaionetissauketeso2",Kind="Voice",Name="Tyviis Gamoyeneba Sisulelea, Baionetis Ki Sauketeso!",Translation="Bullets are foolish, the Bayonet is better!",Asset="rbxassetid://17622523998",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_tyviisgamoyenebasisuleleabaionetissauketeso3",Kind="Voice",Name="Tyviis Gamoyeneba Sisulelea, Baionetis Ki Sauketeso!",Translation="Bullets are foolish, the Bayonet is better!",Asset="rbxassetid://17622534411",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_Imperatorisatvis1",Kind="Voice",Name="Imperatorisatvis!",Translation="For the Emperor!",Asset="rbxassetid://17622569499",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_Imperatorisatvis2",Kind="Voice",Name="Imperatorisatvis!",Translation="For the Emperor!",Asset="rbxassetid://17622572204",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_Imperatorisatvis3",Kind="Voice",Name="Imperatorisatvis!",Translation="For the Emperor!",Asset="rbxassetid://17622574681",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_gmerticvenskenaa1",Kind="Voice",Name="Gmerti Cvenskenaa!",Translation="God is with us!",Asset="rbxassetid://17622583897",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_gmerticvenskenaa2",Kind="Voice",Name="Gmerti Cvenskenaa!",Translation="God is with us!",Asset="rbxassetid://17622587014",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_gmerticvenskenaa3",Kind="Voice",Name="Gmerti Cvenskenaa!",Translation="God is with us!",Asset="rbxassetid://17622590942",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_gaumarjosimperators1",Kind="Voice",Name="Gaumarjos Imperators!",Translation="Long live the Emperor!",Asset="rbxassetid://17622602195",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_gaumarjosimperators2",Kind="Voice",Name="Gaumarjos Imperators!",Translation="Long live the Emperor!",Asset="rbxassetid://17622606536",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_gaumarjosimperators3",Kind="Voice",Name="Gaumarjos Imperators!",Translation="Long live the Emperor!",Asset="rbxassetid://17622608747",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_gaanadgret1",Kind="Voice",Name="Gaanadguret!",Translation="Crush Them!",Asset="rbxassetid://17622628643",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_gaanadgret2",Kind="Voice",Name="Gaanadguret!",Translation="Crush Them!",Asset="rbxassetid://17622631034",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale/geor_gaanadgret3",Kind="Voice",Name="Gaanadguret!",Translation="Crush Them!",Asset="rbxassetid://17622634064",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GeorgianMale",LanguageGroup="Georgian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_beybusurman1",Kind="Voice",Name="Bey Busurman!",Translation="Crush Them!",Asset="rbxassetid://17622346982",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_beybusurman2",Kind="Voice",Name="Bey Busurman!",Translation="Crush Them!",Asset="rbxassetid://17622350795",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_beybusurman3",Kind="Voice",Name="Bey Busurman!",Translation="Crush Them!",Asset="rbxassetid://17622356763",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ura1",Kind="Voice",Name="Ura!",Translation="Ura!",Asset="rbxassetid://17622365145",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ura2",Kind="Voice",Name="Ura!",Translation="Ura!",Asset="rbxassetid://17622368106",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ura3",Kind="Voice",Name="Ura!",Translation="Ura!",Asset="rbxassetid://17622371647",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_SlavsyaOtechestvo1",Kind="Voice",Name="SlavsyaOtechestvo!",Translation="Glory to the fatherland!",Asset="rbxassetid://17622406403",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_SlavsyaOtechestvo2",Kind="Voice",Name="SlavsyaOtechestvo!",Translation="Glory to the fatherland!",Asset="rbxassetid://17622406403",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_SlavsyaOtechestvo3",Kind="Voice",Name="SlavsyaOtechestvo!",Translation="Glory to the fatherland!",Asset="rbxassetid://17622415224",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_PulyaDuraShtykmolodets1",Kind="Voice",Name="Pulya Dura Shtyk molodets!",Translation="Bullets are foolish, the Bayonet is better!",Asset="rbxassetid://17622424170",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_PulyaDuraShtykmolodets2",Kind="Voice",Name="Pulya Dura Shtyk molodets!",Translation="Bullets are foolish, the Bayonet is better!",Asset="rbxassetid://17622426740",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_PulyaDuraShtykmolodets3",Kind="Voice",Name="Pulya Dura Shtyk molodets!",Translation="Bullets are foolish, the Bayonet is better!",Asset="rbxassetid://17622428803",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ZaGosudarya1",Kind="Voice",Name="Za Gosudarya!",Translation="For his majesty!",Asset="rbxassetid://17622443801",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ZaGosudarya2",Kind="Voice",Name="Za Gosudarya!",Translation="For his majesty!",Asset="rbxassetid://17622446118",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ZaGosudarya3",Kind="Voice",Name="Za Gosudarya!",Translation="For his majesty!",Asset="rbxassetid://17622447594",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_VoruiUbivai1",Kind="Voice",Name="Vorui Ubivai!",Translation="Kill! Steal!",Asset="rbxassetid://17622453168",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_VoruiUbivai2",Kind="Voice",Name="Vorui Ubivai!",Translation="Kill! Steal!",Asset="rbxassetid://17622455360",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_VoruiUbivai3",Kind="Voice",Name="Vorui Ubivai!",Translation="Kill! Steal!",Asset="rbxassetid://17622457303",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_SnamiBog1",Kind="Voice",Name="SnamiBog!",Translation="God is with us!",Asset="rbxassetid://17622471191",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_SnamiBog2",Kind="Voice",Name="SnamiBog!",Translation="God is with us!",Asset="rbxassetid://17622472848",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_SnamiBog3",Kind="Voice",Name="SnamiBog!",Translation="God is with us!",Asset="rbxassetid://17622477647",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_DazdravstvuyetTsar1",Kind="Voice",Name="Da zdravstvuyet Tsar!",Translation="Long live the Tsar!",Asset="rbxassetid://17622484764",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_DazdravstvuyetTsar2",Kind="Voice",Name="Da zdravstvuyet Tsar!",Translation="Long live the Tsar!",Asset="rbxassetid://17622486609",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_DazdravstvuyetTsar3",Kind="Voice",Name="Da zdravstvuyet Tsar!",Translation="Long live the Tsar!",Asset="rbxassetid://17622488720",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ZaPobedu1",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622497785",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ZaPobedu2",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622500527",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ZaPobedu3",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622502278",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ZaPobedu4",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622507007",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_ZaPobedu5",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622509403",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_VperedRebyata1",Kind="Voice",Name="Vpered Rebyata!",Translation="Forward Comrades!",Asset="rbxassetid://17622512793",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_VperedRebyata2",Kind="Voice",Name="Vpered Rebyata!",Translation="Forward Comrades!",Asset="rbxassetid://17622515401",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_VperedRebyata3",Kind="Voice",Name="Vpered Rebyata!",Translation="Forward Comrades!",Asset="rbxassetid://17622517723",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_IditeSyuda1",Kind="Voice",Name="Idite Syuda!",Translation="Come here!",Asset="rbxassetid://17622531987",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_IditeSyuda2",Kind="Voice",Name="Idite Syuda!",Translation="Come here!",Asset="rbxassetid://17622534188",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_IditeSyuda3",Kind="Voice",Name="Idite Syuda!",Translation="Come here!",Asset="rbxassetid://17622536024",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_IditeSyuda4",Kind="Voice",Name="Idite Syuda!",Translation="Come here!",Asset="rbxassetid://17622537933",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_StoyatdoSmerti1",Kind="Voice",Name="Stoyatdo Smerti!",Translation="Stand till death!",Asset="rbxassetid://17622543839",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_StoyatdoSmerti2",Kind="Voice",Name="Stoyatdo Smerti!",Translation="Stand till death!",Asset="rbxassetid://17622545280",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_StoyatdoSmerti3",Kind="Voice",Name="Stoyatdo Smerti!",Translation="Stand till death!",Asset="rbxassetid://17622545280",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_Gryaznyyesvini1",Kind="Voice",Name="Gryaznyye svin'i!",Translation="Get those Pigs!",Asset="rbxassetid://17622553038",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_Gryaznyyesvini2",Kind="Voice",Name="Gryaznyye svin'i!",Translation="Get those Pigs!",Asset="rbxassetid://17622554581",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_Gryaznyyesvini3",Kind="Voice",Name="Gryaznyye svin'i!",Translation="Get those Pigs!",Asset="rbxassetid://17622555773",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_DazdravstvuyetAleksandr1",Kind="Voice",Name="Da zdravstvuyet Aleksandr!",Translation="Long live Alexander!",Asset="rbxassetid://17622562113",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_DazdravstvuyetAleksandr2",Kind="Voice",Name="Da zdravstvuyet Aleksandr!",Translation="Long live Alexander!",Asset="rbxassetid://17622564208",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_DazdravstvuyetAleksandr3",Kind="Voice",Name="Da zdravstvuyet Aleksandr!",Translation="Long live Alexander!",Asset="rbxassetid://17622565495",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_OkhrannikDvigaytesVpered1",Kind="Voice",Name="Okhrannik Dvigaytes Vpered!",Translation="Guard Forwards!",Asset="rbxassetid://17622572164",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_OkhrannikDvigaytesVpered2",Kind="Voice",Name="Okhrannik Dvigaytes Vpered!",Translation="Guard Forwards!",Asset="rbxassetid://17622575028",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale/russ_OkhrannikDvigaytesVpered3",Kind="Voice",Name="Okhrannik Dvigaytes Vpered!",Translation="Guard Forwards!",Asset="rbxassetid://17622577575",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianGuardMale",LanguageGroup="RussianGuard"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_beybusurman1",Kind="Voice",Name="Bey Busurman!",Translation="Crush Them!",Asset="rbxassetid://17622346982",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_beybusurman2",Kind="Voice",Name="Bey Busurman!",Translation="Crush Them!",Asset="rbxassetid://17622350795",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_beybusurman3",Kind="Voice",Name="Bey Busurman!",Translation="Crush Them!",Asset="rbxassetid://17622356763",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ura1",Kind="Voice",Name="Ura!",Translation="Ura!",Asset="rbxassetid://17622365145",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ura2",Kind="Voice",Name="Ura!",Translation="Ura!",Asset="rbxassetid://17622368106",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ura3",Kind="Voice",Name="Ura!",Translation="Ura!",Asset="rbxassetid://17622371647",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_SlavsyaOtechestvo1",Kind="Voice",Name="Slavsya Otechestvo!",Translation="Glory to the fatherland!",Asset="rbxassetid://17622406403",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_SlavsyaOtechestvo2",Kind="Voice",Name="Slavsya Otechestvo!",Translation="Glory to the fatherland!",Asset="rbxassetid://17622406403",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_SlavsyaOtechestvo3",Kind="Voice",Name="Slavsya Otechestvo!",Translation="Glory to the fatherland!",Asset="rbxassetid://17622415224",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_PulyaDuraShtykmolodets1",Kind="Voice",Name="Pulya Dura Shtyk molodets!",Translation="Bullets are foolish, the Bayonet is better!",Asset="rbxassetid://17622424170",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_PulyaDuraShtykmolodets2",Kind="Voice",Name="Pulya Dura Shtyk molodets!",Translation="Bullets are foolish, the Bayonet is better!",Asset="rbxassetid://17622426740",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_PulyaDuraShtykmolodets3",Kind="Voice",Name="Pulya Dura Shtyk molodets!",Translation="Bullets are foolish, the Bayonet is better!",Asset="rbxassetid://17622428803",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ZaGosudarya1",Kind="Voice",Name="Za Gosudarya!",Translation="For his majesty!",Asset="rbxassetid://17622443801",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ZaGosudarya2",Kind="Voice",Name="Za Gosudarya!",Translation="For his majesty!",Asset="rbxassetid://17622446118",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ZaGosudarya3",Kind="Voice",Name="Za Gosudarya!",Translation="For his majesty!",Asset="rbxassetid://17622447594",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_VoruiUbivai1",Kind="Voice",Name="Vorui Ubivai!",Translation="Kill! Steal!",Asset="rbxassetid://17622453168",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_VoruiUbivai2",Kind="Voice",Name="Vorui Ubivai!",Translation="Kill! Steal!",Asset="rbxassetid://17622455360",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_VoruiUbivai3",Kind="Voice",Name="Vorui Ubivai!",Translation="Kill! Steal!",Asset="rbxassetid://17622457303",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_SnamiBog1",Kind="Voice",Name="SnamiBog!",Translation="God is with us!",Asset="rbxassetid://17622471191",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_SnamiBog2",Kind="Voice",Name="SnamiBog!",Translation="God is with us!",Asset="rbxassetid://17622472848",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_SnamiBog3",Kind="Voice",Name="SnamiBog!",Translation="God is with us!",Asset="rbxassetid://17622477647",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_DazdravstvuyetTsar1",Kind="Voice",Name="Da zdravstvuyet Tsar!",Translation="Long live the Tsar!",Asset="rbxassetid://17622484764",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_DazdravstvuyetTsar2",Kind="Voice",Name="Da zdravstvuyet Tsar!",Translation="Long live the Tsar!",Asset="rbxassetid://17622486609",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_DazdravstvuyetTsar3",Kind="Voice",Name="Da zdravstvuyet Tsar!",Translation="Long live the Tsar!",Asset="rbxassetid://17622488720",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ZaPobedu1",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622497785",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ZaPobedu2",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622500527",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ZaPobedu3",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622502278",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ZaPobedu4",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622507007",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_ZaPobedu5",Kind="Voice",Name="Za Pobedu!",Translation="For victory!",Asset="rbxassetid://17622509403",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_VperedRebyata1",Kind="Voice",Name="Vpered Rebyata!",Translation="Forward Comrades!",Asset="rbxassetid://17622512793",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_VperedRebyata2",Kind="Voice",Name="Vpered Rebyata!",Translation="Forward Comrades!",Asset="rbxassetid://17622515401",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_VperedRebyata3",Kind="Voice",Name="Vpered Rebyata!",Translation="Forward Comrades!",Asset="rbxassetid://17622517723",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_IditeSyuda1",Kind="Voice",Name="Idite Syuda!",Translation="Come here!",Asset="rbxassetid://17622531987",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_IditeSyuda2",Kind="Voice",Name="Idite Syuda!",Translation="Come here!",Asset="rbxassetid://17622534188",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_IditeSyuda3",Kind="Voice",Name="Idite Syuda!",Translation="Come here!",Asset="rbxassetid://17622536024",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_IditeSyuda4",Kind="Voice",Name="Idite Syuda!",Translation="Come here!",Asset="rbxassetid://17622537933",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_StoyatdoSmerti1",Kind="Voice",Name="Stoyatdo Smerti!",Translation="Stand till death!",Asset="rbxassetid://17622543839",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_StoyatdoSmerti2",Kind="Voice",Name="Stoyatdo Smerti!",Translation="Stand till death!",Asset="rbxassetid://17622545280",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_StoyatdoSmerti3",Kind="Voice",Name="Stoyatdo Smerti!",Translation="Stand till death!",Asset="rbxassetid://17622545280",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_Gryaznyyesvini1",Kind="Voice",Name="Gryaznyye svin'i!",Translation="Get those Pigs!",Asset="rbxassetid://17622553038",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_Gryaznyyesvini2",Kind="Voice",Name="Gryaznyye svin'i!",Translation="Get those Pigs!",Asset="rbxassetid://17622554581",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_Gryaznyyesvini3",Kind="Voice",Name="Gryaznyye svin'i!",Translation="Get those Pigs!",Asset="rbxassetid://17622555773",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_DazdravstvuyetAleksandr1",Kind="Voice",Name="Da zdravstvuyet Aleksandr!",Translation="Long live Alexander!",Asset="rbxassetid://17622562113",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_DazdravstvuyetAleksandr2",Kind="Voice",Name="Da zdravstvuyet Aleksandr!",Translation="Long live Alexander!",Asset="rbxassetid://17622564208",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_DazdravstvuyetAleksandr3",Kind="Voice",Name="Da zdravstvuyet Aleksandr!",Translation="Long live Alexander!",Asset="rbxassetid://17622565495",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_OkhrannikDvigaytesVpered1",Kind="Voice",Name="Okhrannik Dvigaytes Vpered!",Translation="Guard Forwards!",Asset="rbxassetid://17622572164",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_OkhrannikDvigaytesVpered2",Kind="Voice",Name="Okhrannik Dvigaytes Vpered!",Translation="Guard Forwards!",Asset="rbxassetid://17622575028",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale/russ_OkhrannikDvigaytesVpered3",Kind="Voice",Name="Okhrannik Dvigaytes Vpered!",Translation="Guard Forwards!",Asset="rbxassetid://17622577575",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RussianMale",LanguageGroup="Russian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Nimic1",Kind="Voice",Name="Nimic fără dumnezeu!",Translation="Nothing without God!",Asset="rbxassetid://115808855267821",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Nimic2",Kind="Voice",Name="Nimic fără dumnezeu!",Translation="Nothing without God!",Asset="rbxassetid://75482616654115",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Nimic3",Kind="Voice",Name="Nimic fără dumnezeu!",Translation="Nothing without God!",Asset="rbxassetid://95234985533205",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_InIad1",Kind="Voice",Name="Trimiteți-i în iad!",Translation="Send them to hell!",Asset="rbxassetid://80037598261705",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_InIad2",Kind="Voice",Name="Trimiteți-i în iad!",Translation="Send them to hell!",Asset="rbxassetid://103814445172435",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_InIad3",Kind="Voice",Name="Trimiteți-i în iad!",Translation="Send them to hell!",Asset="rbxassetid://71636529427767",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Picioare1",Kind="Voice",Name="Călcați-i în picioare!",Translation="Trample them underfoot!",Asset="rbxassetid://75674658818955",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Picioare2",Kind="Voice",Name="Călcați-i în picioare!",Translation="Trample them underfoot!",Asset="rbxassetid://101316396422044",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Picioare3",Kind="Voice",Name="Călcați-i în picioare!",Translation="Trample them underfoot!",Asset="rbxassetid://107862107157112",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Alexandru1",Kind="Voice",Name="Trăiască țarul Alexandru!",Translation="Long live Tsar Alexander!",Asset="rbxassetid://71049169779108",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Alexandru2",Kind="Voice",Name="Trăiască țarul Alexandru!",Translation="Long live Tsar Alexander!",Asset="rbxassetid://129069679281378",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Alexandru3",Kind="Voice",Name="Trăiască țarul Alexandru!",Translation="Long live Tsar Alexander!",Asset="rbxassetid://137587669153850",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Bucati1",Kind="Voice",Name="Rupeți-i în bucăți, nu le dați înapoi!",Translation="Tear them to shreds!",Asset="rbxassetid://139621577876863",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Bucati2",Kind="Voice",Name="Rupeți-i în bucăți, nu le dați înapoi!",Translation="Tear them to shreds!",Asset="rbxassetid://132449354478990",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Bucati3",Kind="Voice",Name="Rupeți-i în bucăți, nu le dați înapoi!",Translation="Tear them to shreds!",Asset="rbxassetid://105954808334485",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Glorie1",Kind="Voice",Name="Glorie ori moarte!",Translation="Glory or death!",Asset="rbxassetid://75734320076670",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Glorie2",Kind="Voice",Name="Glorie ori moarte!",Translation="Glory or death!",Asset="rbxassetid://83096721977594",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Glorie3",Kind="Voice",Name="Glorie ori moarte!",Translation="Glory or death!",Asset="rbxassetid://74250175406795",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Demni1",Kind="Voice",Name="Să fim demni de numele nostru!",Translation="Let's live up to our name!",Asset="rbxassetid://101508999380619",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Demni2",Kind="Voice",Name="Să fim demni de numele nostru!",Translation="Let's live up to our name!",Asset="rbxassetid://123566771569735",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Demni3",Kind="Voice",Name="Să fim demni de numele nostru!",Translation="Let's live up to our name!",Asset="rbxassetid://96518700489247",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Ura1",Kind="Voice",Name="Ura!",Translation="Ura!",Asset="rbxassetid://87111258323704",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Ura2",Kind="Voice",Name="Ura!",Translation="Ura!",Asset="rbxassetid://70699460858384",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Ura3",Kind="Voice",Name="Ura!",Translation="Ura!",Asset="rbxassetid://130769232976407",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Victo1",Kind="Voice",Name="Victoria e a noastra!",Translation="Victory is ours!",Asset="rbxassetid://80467048174504",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Victo2",Kind="Voice",Name="Victoria e a noastra!",Translation="Victory is ours!",Asset="rbxassetid://134009448103846",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Victo3",Kind="Voice",Name="Victoria e a noastra!",Translation="Victory is ours!",Asset="rbxassetid://81066320204689",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Trimi1",Kind="Voice",Name="Sa-i trimitem la drac!",Translation="Send them to hell!",Asset="rbxassetid://130647432595637",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Trimi2",Kind="Voice",Name="Sa-i trimitem la drac!",Translation="Send them to hell!",Asset="rbxassetid://99757545928692",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Trimi3",Kind="Voice",Name="Sa-i trimitem la drac!",Translation="Send them to hell!",Asset="rbxassetid://87223806681987",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Trece1",Kind="Voice",Name="Pe aici nu se trece!",Translation="You cant pass through here!",Asset="rbxassetid://131568688387750",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Trece2",Kind="Voice",Name="Pe aici nu se trece!",Translation="You cant pass through here!",Asset="rbxassetid://120062913413090",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Trece3",Kind="Voice",Name="Pe aici nu se trece!",Translation="You cant pass through here!",Asset="rbxassetid://72805729886581",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Cedati1",Kind="Voice",Name="Nu cedati!",Translation="Dont let up!",Asset="rbxassetid://130643482215966",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Cedati2",Kind="Voice",Name="Nu cedati!",Translation="Dont let up!",Asset="rbxassetid://120404016676944",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Cedati3",Kind="Voice",Name="Nu cedati!",Translation="Dont let up!",Asset="rbxassetid://94976324498772",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Exista1",Kind="Voice",Name="Exista o singura cale, inainte!",Translation="Theres only one way, forward!",Asset="rbxassetid://119064660074280",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Exista2",Kind="Voice",Name="Exista o singura cale, inainte!",Translation="Theres only one way, forward!",Asset="rbxassetid://76045068219382",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Exista3",Kind="Voice",Name="Exista o singura cale, inainte!",Translation="Theres only one way, forward!",Asset="rbxassetid://118668604519872",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Noastra1",Kind="Voice",Name="Cu foc si cu sabie, aparam gloria noastra!",Translation="With fire and sword, we defend our glory!",Asset="rbxassetid://93323716246928",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Noastra2",Kind="Voice",Name="Cu foc si cu sabie, aparam gloria noastra!",Translation="With fire and sword, we defend our glory!",Asset="rbxassetid://105977563408474",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale/RomanianTsar_Noastra3",Kind="Voice",Name="Cu foc si cu sabie, aparam gloria noastra!",Translation="With fire and sword, we defend our glory!",Asset="rbxassetid://80606308662532",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/RomanianTsarMale",LanguageGroup="RomanianTsar"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_king1",Kind="Voice",Name="¡Por Dios, y por el Rey!",Translation="For God, and for the King!",Asset="rbxassetid://682082352",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_king2",Kind="Voice",Name="¡Por nuestro Rey!",Translation="For our King!",Asset="rbxassetid://682084301",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_glory1",Kind="Voice",Name="¡Por la gloria!",Translation="For the glory!",Asset="rbxassetid://721339894",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_glory2",Kind="Voice",Name="¡Gloria, o muerte!",Translation="Glory or death!",Asset="rbxassetid://721339781",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_glory3",Kind="Voice",Name="¡Buen día para luchar!",Translation="Good day to fight!",Asset="rbxassetid://682078330",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_glory4",Kind="Voice",Name="¡Antes morir que sufrir una deshonra!",Translation="Rather die than suffer disgrace!",Asset="rbxassetid://721339666",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_glory5",Kind="Voice",Name="¡Fuerza, y honor!",Translation="Strength, and honour!",Asset="rbxassetid://721340484",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_glory6",Kind="Voice",Name="¡Somos poderosos, y no nos rendimos!",Translation="We are powerful, and we do not surrender!",Asset="rbxassetid://721340139",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_god1",Kind="Voice",Name="¡Que Dios nos proteja!",Translation="May god protect us!",Asset="rbxassetid://721356858",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_god2",Kind="Voice",Name="¡Que el señor nos proteja!",Translation="May the lord protect us!",Asset="rbxassetid://733054769",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_insult1",Kind="Voice",Name="¡Hah, son presa facil!",Translation="Hah, they're easy prey!",Asset="rbxassetid://682078330",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_hurrah1",Kind="Voice",Name="¡Hurrah!",Translation="Hurrah!",Asset="rbxassetid://721338416",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_hurrah2",Kind="Voice",Name="¡Hurrah!",Translation="Hurrah!",Asset="rbxassetid://733055391",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_hurrah3",Kind="Voice",Name="¡Hurrah, hurrah!",Translation="Hurrah, hurrah!",Asset="rbxassetid://721338662",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_attack1",Kind="Voice",Name="¡Al ataque!",Translation="Attack!",Asset="rbxassetid://682084787",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_attack2",Kind="Voice",Name="¡Al ataque!",Translation="Attack!",Asset="rbxassetid://733098292",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_attack3",Kind="Voice",Name="¡Al ataque!",Translation="Attack!",Asset="rbxassetid://733098382",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_attack4",Kind="Voice",Name="¡Por el Rey, al ataque!",Translation="For the King, attack!",Asset="rbxassetid://682084155",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_attack5",Kind="Voice",Name="¡Al ataque deprisa!",Translation="Quick, attack!",Asset="rbxassetid://682085740",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_charge1",Kind="Voice",Name="¡A la carga!",Translation="Charge!",Asset="rbxassetid://682084538",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_charge2",Kind="Voice",Name="¡A la carga!",Translation="Charge!",Asset="rbxassetid://721336600",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_charge3",Kind="Voice",Name="¡A la carga!",Translation="Charge!",Asset="rbxassetid://726445802",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_fillgaps",Kind="Voice",Name="¡Cierren filas!",Translation="Close the line!",Asset="rbxassetid://721336286",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_destroy1",Kind="Voice",Name="¡Destrúyanlos!",Translation="Destroy them!",Asset="rbxassetid://721339566",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_destroy2",Kind="Voice",Name="¡Aplástenlos como moscas!",Translation="Stomp them like flies!",Asset="rbxassetid://721340385",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_destroy3",Kind="Voice",Name="¡Aplástenlos!",Translation="Stomp them!",Asset="rbxassetid://721340272",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_withme1",Kind="Voice",Name="¡Conmigo!",Translation="With me!",Asset="rbxassetid://719600077",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale/spanish_withme2",Kind="Voice",Name="¡Reagrúpense!",Translation="Regroup!",Asset="rbxassetid://721333334",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/FrenchSpanishMale",LanguageGroup="FrenchSpanish"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_gloria",Kind="Voice",Name="Per la gloria!",Translation="?",Asset="rbxassetid://86645626200203",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_carica1",Kind="Voice",Name="Carica!",Translation="?",Asset="rbxassetid://84127628656834",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_carica2",Kind="Voice",Name="Careyeca!",Translation="?",Asset="rbxassetid://103027519424670",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_onore",Kind="Voice",Name="Per l'onore e la gloria!",Translation="?",Asset="rbxassetid://95854829958538",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_loro1",Kind="Voice",Name="Schiantateli!",Translation="?",Asset="rbxassetid://77055237155606",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_loro2",Kind="Voice",Name="Attack!",Translation="?",Asset="rbxassetid://124413131121363",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_morti",Kind="Voice",Name="Gloria o morte!",Translation="?",Asset="rbxassetid://114575129030642",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_prima",Kind="Voice",Name="Meglio la morte che il disonore!",Translation="?",Asset="rbxassetid://100207747628368",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_hurrah1",Kind="Voice",Name="Hurrah!",Translation="?",Asset="rbxassetid://92242244357747",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_hurrah2",Kind="Voice",Name="Hurrah Hurrah!",Translation="?",Asset="rbxassetid://121502821954608",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_avanti",Kind="Voice",Name="Avanti!",Translation="?",Asset="rbxassetid://97404618405366",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_vittoria1",Kind="Voice",Name="Vittoria!",Translation="?",Asset="rbxassetid://99563239676279",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_vittoria2",Kind="Voice",Name="Vittoria!",Translation="?",Asset="rbxassetid://127761002769205",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_guardia",Kind="Voice",Name="La Guardia non si arrende!",Translation="?",Asset="rbxassetid://101562570378696",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale/italy_guardia2",Kind="Voice",Name="La Guardia non si arrende!",Translation="?",Asset="rbxassetid://118213736517402",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ItalianLQMale",LanguageGroup="ItalianLQ"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale/target_1",Kind="Voice",Name="🌾",Translation="🌾",Asset="rbxassetid://9113470014",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale",LanguageGroup="Target"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale/target_2",Kind="Voice",Name="🌾🗣️",Translation="🌾🗣️",Asset="rbxassetid://9114655348",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale",LanguageGroup="Target"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale/target_3",Kind="Voice",Name="🌾❗",Translation="🌾❗",Asset="rbxassetid://9113470020",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale",LanguageGroup="Target"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale/target_4",Kind="Voice",Name="🌾❗",Translation="🌾❗",Asset="rbxassetid://9113469292",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale",LanguageGroup="Target"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale/target_5",Kind="Voice",Name="🌾",Translation="🌾",Asset="rbxassetid://9114034463",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale",LanguageGroup="Target"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale/target_6",Kind="Voice",Name="🍂",Translation="🍂",Asset="rbxassetid://9114518070",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/TargetMale",LanguageGroup="Target"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AstartesMale/emperor",Kind="Voice",Name="For the Emperor!",Translation="For the Emperor!",Asset="rbxassetid://110085128671092",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AstartesMale",LanguageGroup="Astartes"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AstartesMale/lasgun",Kind="Voice",Name="PEW!",Translation="PEW!",Asset="rbxassetid://2836444230",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AstartesMale",LanguageGroup="Astartes"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AstartesMale/lasgun2",Kind="Voice",Name="BANG!",Translation="BANG!",Asset="rbxassetid://563593610",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AstartesMale",LanguageGroup="Astartes"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_juris1",Kind="Voice",Name="Juriš!",Translation="Charge!",Asset="rbxassetid://128901286261935",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_juris2",Kind="Voice",Name="Juriš!",Translation="Charge!",Asset="rbxassetid://127584471079391",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_juris3",Kind="Voice",Name="Juriš!",Translation="Charge!",Asset="rbxassetid://106438256665647",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_juris4",Kind="Voice",Name="Juriš!",Translation="Charge!",Asset="rbxassetid://115218850644158",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_kroz1",Kind="Voice",Name="Kroz krv, do slave!",Translation="Through blood, to glory!",Asset="rbxassetid://104794892487600",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_samo1",Kind="Voice",Name="Samo napred, bez straha!",Translation="Only forwards, without fear!",Asset="rbxassetid://77966309564304",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_samo2",Kind="Voice",Name="Samo napred, bez straha!",Translation="Only forwards, without fear!",Asset="rbxassetid://140616311564470",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_braco1",Kind="Voice",Name="U boj braćo, do zadnjeg daha!",Translation="To the battle brothers, until the last breath!",Asset="rbxassetid://110988807787043",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_napad1",Kind="Voice",Name="U napad!",Translation="Attack!",Asset="rbxassetid://120819987759926",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_napad2",Kind="Voice",Name="U napad!",Translation="Attack!",Asset="rbxassetid://130634941085702",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_zamnom1",Kind="Voice",Name="Zamnom braćo!",Translation="Follow me brothers!",Asset="rbxassetid://100153658293574",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_slobodu1",Kind="Voice",Name="Za slobodu!",Translation="For freedom!",Asset="rbxassetid://117940514333574",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale/serbian_zara1",Kind="Voice",Name="Za Cara!",Translation="For the Kaiser!",Asset="rbxassetid://103256781784853",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SerbianMale",LanguageGroup="Serbian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_sultan1",Kind="Voice",Name="ʿAla wdd es-Sulṭān!",Translation="For the Sultan!",Asset="rbxassetid://72891396257361",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_sultan2",Kind="Voice",Name="ʿAla wdd es-Sulṭān!",Translation="For the Sultan!",Asset="rbxassetid://91396434779403",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_sultan3",Kind="Voice",Name="ʿAla wdd es-Sulṭān!",Translation="For the Sultan!",Asset="rbxassetid://98716348037086",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_dey1",Kind="Voice",Name="ʿAla wdd ed-Dāy!",Translation="For the Dey!",Asset="rbxassetid://78872008461209",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_dey2",Kind="Voice",Name="ʿAla wdd ed-Dāy!",Translation="For the Dey!",Asset="rbxassetid://108646423941052",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_dey3",Kind="Voice",Name="ʿAla wdd ed-Dāy!",Translation="For the Dey!",Asset="rbxassetid://104696765994521",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_attack1",Kind="Voice",Name="Hajmūh!",Translation="Attack them!",Asset="rbxassetid://128383590421862",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_attack2",Kind="Voice",Name="Hajmūh!",Translation="Attack them!",Asset="rbxassetid://136774439449407",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_attack3",Kind="Voice",Name="Hajmūh!",Translation="Attack them!",Asset="rbxassetid://84332777843851",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_strike1",Kind="Voice",Name="Kabbū ʿalihom!",Translation="Strike them down!",Asset="rbxassetid://137109983806491",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_strike2",Kind="Voice",Name="Kabbū ʿalihom!",Translation="Strike them down!",Asset="rbxassetid://94371329959659",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_strike3",Kind="Voice",Name="Kabbū ʿalihom!",Translation="Strike them down!",Asset="rbxassetid://95918402110722",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_empire1",Kind="Voice",Name="Taʿīsh ed-Dawla el-ʿUthmāniyya!",Translation="Long live the Ottoman Empire!",Asset="rbxassetid://88399491462876",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_empire2",Kind="Voice",Name="Taʿīsh ed-Dawla el-ʿUthmāniyya!",Translation="Long live the Ottoman Empire!",Asset="rbxassetid://105288736940671",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_empire3",Kind="Voice",Name="Taʿīsh ed-Dawla el-ʿUthmāniyya!",Translation="Long live the Ottoman Empire!",Asset="rbxassetid://129985176761139",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_ship1",Kind="Voice",Name="Ḡarrqū lehom el-bawākher!",Translation="Sink their ships!",Asset="rbxassetid://132915734091187",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_ship2",Kind="Voice",Name="Ḡarrqū lehom el-bawākher!",Translation="Sink their ships!",Asset="rbxassetid://88678263960484",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_ship3",Kind="Voice",Name="Ḡarrqū lehom el-bawākher!",Translation="Sink their ships!",Asset="rbxassetid://100249583271341",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_forward1",Kind="Voice",Name="Qaddām, yā lejāq!",Translation="Forward, Odjaks!",Asset="rbxassetid://74044014253408",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_forward2",Kind="Voice",Name="Qaddām, yā lejāq!",Translation="Forward, Odjaks!",Asset="rbxassetid://74147828685658",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_forward3",Kind="Voice",Name="Qaddām, yā lejāq!",Translation="Forward, Odjaks!",Asset="rbxassetid://71364922796911",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_shores1",Kind="Voice",Name="Khrejūhum mn swāḥilnā!",Translation="Drive them off our shores!",Asset="rbxassetid://119062245541949",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_shores2",Kind="Voice",Name="Khrejūhum mn swāḥilnā!",Translation="Drive them off our shores!",Asset="rbxassetid://77214303856041",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/maghreb_shores3",Kind="Voice",Name="Khrejūhum mn swāḥilnā!",Translation="Drive them off our shores!",Asset="rbxassetid://133238713636228",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/turkish_allah1",Kind="Voice",Name="Allah! Allah! Allah!",Translation="Allah! Allah! Allah!",Asset="rbxassetid://12522671927",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/turkish_allah2",Kind="Voice",Name="Allah!",Translation="Allah!",Asset="rbxassetid://12522671987",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale/turkish_allah3",Kind="Voice",Name="Allah! Allah!",Translation="Allah! Allah!",Asset="rbxassetid://12522672049",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMaghrebMale",LanguageGroup="OttomanMaghreb"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_sultan1",Kind="Voice",Name="ʿAla wdd es-Sulṭān!",Translation="For the Sultan!",Asset="rbxassetid://90588919392080",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_sultan2",Kind="Voice",Name="ʿAla wdd es-Sulṭān!",Translation="For the Sultan!",Asset="rbxassetid://79678826345900",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_sultan3",Kind="Voice",Name="ʿAla wdd es-Sulṭān!",Translation="For the Sultan!",Asset="rbxassetid://126818539797481",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_dey1",Kind="Voice",Name="ʿala wdd Dāy el-Jazāʾir!",Translation="For the Dey of Algiers!",Asset="rbxassetid://112706882270269",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_dey2",Kind="Voice",Name="ʿala wdd Dāy el-Jazāʾir!",Translation="For the Dey of Algiers!",Asset="rbxassetid://128337863135735",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_dey3",Kind="Voice",Name="ʿala wdd Dāy el-Jazāʾir!",Translation="For the Dey of Algiers!",Asset="rbxassetid://97147918649280",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_attack1",Kind="Voice",Name="Hajmūh!",Translation="Attack them!",Asset="rbxassetid://128383590421862",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_attack2",Kind="Voice",Name="Hajmūh!",Translation="Attack them!",Asset="rbxassetid://136774439449407",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_attack3",Kind="Voice",Name="Hajmūh!",Translation="Attack them!",Asset="rbxassetid://84332777843851",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_strike1",Kind="Voice",Name="Kabbū ʿalihom!",Translation="Strike them down!",Asset="rbxassetid://86478758651592",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_strike2",Kind="Voice",Name="Kabbū ʿalihom!",Translation="Strike them down!",Asset="rbxassetid://87757335140600",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_strike3",Kind="Voice",Name="Kabbū ʿalihom!",Translation="Strike them down!",Asset="rbxassetid://95951723346492",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_empire1",Kind="Voice",Name="Taʿīsh ed-Dawla el-ʿUthmāniyya!",Translation="Long live the Ottoman Empire!",Asset="rbxassetid://85395438819606",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_empire2",Kind="Voice",Name="Taʿīsh ed-Dawla el-ʿUthmāniyya!",Translation="Long live the Ottoman Empire!",Asset="rbxassetid://127611843075670",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_empire3",Kind="Voice",Name="Taʿīsh ed-Dawla el-ʿUthmāniyya!",Translation="Long live the Ottoman Empire!",Asset="rbxassetid://116064722420335",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_ship1",Kind="Voice",Name="Ḡarrqū lehom el-bawākher!",Translation="Sink their ships!",Asset="rbxassetid://100249583271341",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_ship2",Kind="Voice",Name="Ḡarrqū lehom el-bawākher!",Translation="Sink their ships!",Asset="rbxassetid://132915734091187",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_ship3",Kind="Voice",Name="Ḡarrqū lehom el-bawākher!",Translation="Sink their ships!",Asset="rbxassetid://88678263960484",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_forward1",Kind="Voice",Name="Qaddām, yā lejāq!",Translation="Forward, Odjaks!",Asset="rbxassetid://131228535895212",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_forward2",Kind="Voice",Name="Qaddām, yā lejāq!",Translation="Forward, Odjaks!",Asset="rbxassetid://121377721809820",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_forward3",Kind="Voice",Name="Qaddām, yā lejāq!",Translation="Forward, Odjaks!",Asset="rbxassetid://101381261356283",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_shores1",Kind="Voice",Name="Khrejūhum mn swāḥilnā!",Translation="Drive them off our shores!",Asset="rbxassetid://119062245541949",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_shores2",Kind="Voice",Name="Khrejūhum mn swāḥilnā!",Translation="Drive them off our shores!",Asset="rbxassetid://77214303856041",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_shores3",Kind="Voice",Name="Khrejūhum mn swāḥilnā!",Translation="Drive them off our shores!",Asset="rbxassetid://133238713636228",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_algiers1",Kind="Voice",Name="taʿīsh el-Jazāʾir!",Translation="Long live Algiers!",Asset="rbxassetid://81257430809478",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_algiers2",Kind="Voice",Name="taʿīsh el-Jazāʾir!",Translation="Long live Algiers!",Asset="rbxassetid://82775323694084",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/ujaq_algiers3",Kind="Voice",Name="taʿīsh el-Jazāʾir!",Translation="Long live Algiers!",Asset="rbxassetid://101707774299101",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/turkish_allah1",Kind="Voice",Name="Allah! Allah! Allah!",Translation="Allah! Allah! Allah!",Asset="rbxassetid://12522671927",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/turkish_allah2",Kind="Voice",Name="Allah!",Translation="Allah!",Asset="rbxassetid://12522671987",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale/turkish_allah3",Kind="Voice",Name="Allah! Allah!",Translation="Allah! Allah!",Asset="rbxassetid://12522672049",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanUjaqMale",LanguageGroup="OttomanUjaq"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_furkaiser1",Kind="Voice",Name="Für den Kaiser!",Translation="For the Kaiser!",Asset="rbxassetid://12456459346",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_furkaiser2",Kind="Voice",Name="Für den Kaiser!",Translation="For the Kaiser!",Asset="rbxassetid://12456459942",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_furkaiser3",Kind="Voice",Name="Für den Kaiser!",Translation="For the Kaiser!",Asset="rbxassetid://12456460287",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_carica1",Kind="Voice",Name="Carica!",Translation="Carica!",Asset="rbxassetid://990517159",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_hurrah1",Kind="Voice",Name="Hurrah!",Translation="Hurrah!",Asset="rbxassetid://12589597965",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_hurrah2",Kind="Voice",Name="Hurrah Hurrah!",Translation="Hurrah Hurrah!",Asset="rbxassetid://12589598741",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_morti",Kind="Voice",Name="Gloria o morte!",Translation="Victory or death!",Asset="rbxassetid://990514864",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_avanti",Kind="Voice",Name="Avanti!",Translation="?",Asset="rbxassetid://12589596919",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_furvaterland1",Kind="Voice",Name="Für das Vaterland!",Translation="For the Fatherland!",Asset="rbxassetid://12456458898",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_furvaterland2",Kind="Voice",Name="Für das Vaterland!",Translation="For the Fatherland!",Asset="rbxassetid://12456459635",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_furvaterland3",Kind="Voice",Name="Für das Vaterland!",Translation="For the Fatherland!",Asset="rbxassetid://12456458338",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_charge1",Kind="Voice",Name="Angriff!",Translation="Charge!",Asset="rbxassetid://12456462411",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_charge2",Kind="Voice",Name="Angriff!",Translation="Charge!",Asset="rbxassetid://12456462145",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_charge3",Kind="Voice",Name="Angriff!",Translation="Charge!",Asset="rbxassetid://12456461914",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_forward1",Kind="Voice",Name="Vorwärts Kameraden!",Translation="Forwards Comrades!",Asset="rbxassetid://12456457416",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_forward2",Kind="Voice",Name="Vorwärts Kameraden!",Translation="Forwards Comrades!",Asset="rbxassetid://12456457686",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale/germanItalian_forward3",Kind="Voice",Name="Vorwärts Kameraden!",Translation="Forwards Comrades!",Asset="rbxassetid://12456457897",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanItalianMale",LanguageGroup="GermanItalian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_dia1",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://5988860298",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_dia2",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://5988860624",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_dia3",Kind="Voice",Name="Dia Sabháil Éire!",Translation="God Save Ireland!",Asset="rbxassetid://5988860997",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_erin1",Kind="Voice",Name="Erin go Bragh!",Translation="Ireland Forever!",Asset="rbxassetid://5988861675",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_erin2",Kind="Voice",Name="Erin go Bragh!",Translation="Ireland Forever!",Asset="rbxassetid://5988862017",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_erin3",Kind="Voice",Name="Erin go Bragh!",Translation="Ireland Forever!",Asset="rbxassetid://5988862481",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_nar1",Kind="Voice",Name="Nár laga Dhia thú!",Translation="May God Protect You!",Asset="rbxassetid://5988862798",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_nar2",Kind="Voice",Name="Nár laga Dhia thú!",Translation="May God Protect You!",Asset="rbxassetid://5988863066",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_nar3",Kind="Voice",Name="Nár laga Dhia thú!",Translation="May God Protect You!",Asset="rbxassetid://5988864229",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_abu1",Kind="Voice",Name="Abú!",Translation="Forever!",Asset="rbxassetid://5988856983",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_abu2",Kind="Voice",Name="Abú!",Translation="Forever!",Asset="rbxassetid://5988857644",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_abu3",Kind="Voice",Name="Abú!",Translation="Forever!",Asset="rbxassetid://5988858778",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_saorise1",Kind="Voice",Name="Saoirse nó Bás!",Translation="Freedom or Death!",Asset="rbxassetid://5988859181",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_saorise2",Kind="Voice",Name="Saoirse nó Bás!",Translation="Freedom or Death!",Asset="rbxassetid://5988859543",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/irish_saorise3",Kind="Voice",Name="Saoirse nó Bás!",Translation="Freedom or Death!",Asset="rbxassetid://5988859841",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/america_george",Kind="Voice",Name="This one's for King George!",Translation="This one's for King George!",Asset="rbxassetid://6754842824",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/america_huzzah1",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://612716913",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale/america_huzzah2",Kind="Voice",Name="Huzzah!",Translation="Huzzah!",Asset="rbxassetid://630844989",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/IrishAmericanMale",LanguageGroup="IrishAmerican"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_eternal_1",Kind="Voice",Name="Andour Eternal!",Translation="Andour Eternal!",Asset="rbxassetid://71853511880086",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_eternal_2",Kind="Voice",Name="Andour Eternal!",Translation="Andour Eternal!",Asset="rbxassetid://128740712038581",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_citadel_1",Kind="Voice",Name="The Citadel Stands Tall!",Translation="The Citadel Stands Tall!",Asset="rbxassetid://137145024494585",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_name_1",Kind="Voice",Name="In The Name of The High King!",Translation="In The Name of The High King!",Asset="rbxassetid://139092419677777",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_name_2",Kind="Voice",Name="In The Name of The High King!",Translation="In The Name of The High King!",Asset="rbxassetid://120460672360784",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_way_1",Kind="Voice",Name="The Way Forwards is Paved With Glory!",Translation="The Way Forwards is Paved With Glory!",Asset="rbxassetid://92983303830804",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_way_2",Kind="Voice",Name="The Way Forwards is Paved With Glory!",Translation="The Way Forwards is Paved With Glory!",Asset="rbxassetid://78976187365773",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_sunman_1",Kind="Voice",Name="Sunman Grant Us Strength!",Translation="Sunman Grant Us Strength!",Asset="rbxassetid://95981678181500",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_sunman_2",Kind="Voice",Name="Sunman Grant Us Strength!",Translation="Sunman Grant Us Strength!",Asset="rbxassetid://121655836003692",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_glory_1",Kind="Voice",Name="Alghrim's Glory!",Translation="Alghrim's Glory!",Asset="rbxassetid://105203277154128",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_glory_2",Kind="Voice",Name="Alghrim's Glory!",Translation="Alghrim's Glory!",Asset="rbxassetid://86842372563338",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_purge_1",Kind="Voice",Name="To Purge the Malfeasance!",Translation="To Purge the Malfeasance!",Asset="rbxassetid://122340412830605",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale/andour_purge_2",Kind="Voice",Name="To Purge the Malfeasance!",Translation="To Purge the Malfeasance!",Asset="rbxassetid://81398090475344",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranFemale",LanguageGroup="Andouran"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch/andour_light",Kind="Voice",Name="I am the Light!",Translation="I am the Light!",Asset="rbxassetid://108257939952006",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch",LanguageGroup="AndouranChurch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch/andour_heretic",Kind="Voice",Name="Begone foul Heretic!",Translation="Begone foul Heretic!",Asset="rbxassetid://86500238085776",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch",LanguageGroup="AndouranChurch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch/andour_repent",Kind="Voice",Name="Repent!",Translation="Repent!",Asset="rbxassetid://130293275502722",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch",LanguageGroup="AndouranChurch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch/andour_sunman",Kind="Voice",Name="Sunman grant us strength!",Translation="Sunman grant us strength!",Asset="rbxassetid://79816108393705",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch",LanguageGroup="AndouranChurch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch/andour_malf",Kind="Voice",Name="To purge the Malfesence!",Translation="To purge the Malfesence!",Asset="rbxassetid://106800194466390",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch",LanguageGroup="AndouranChurch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch/andour_burn",Kind="Voice",Name="Burn, burn, burn!",Translation="Burn, burn, burn!",Asset="rbxassetid://122970574342485",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranChurch",LanguageGroup="AndouranChurch"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_hell1",Kind="Voice",Name="Send dem til helvete!",Translation="Send them to hell!",Asset="rbxassetid://100698242371177",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_hell2",Kind="Voice",Name="Send dem til helvete!",Translation="Send them to hell!",Asset="rbxassetid://75790482012651",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_hell3",Kind="Voice",Name="Send dem til helvete!",Translation="Send them to hell!",Asset="rbxassetid://136049313406294",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_god1",Kind="Voice",Name="Gud er med oss!",Translation="God is with us!",Asset="rbxassetid://86770921156106",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_god2",Kind="Voice",Name="Gud er med oss!",Translation="God is with us!",Asset="rbxassetid://72177489954341",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_god3",Kind="Voice",Name="Gud er med oss!",Translation="God is with us!",Asset="rbxassetid://130361946477294",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_forwards1",Kind="Voice",Name="Fremover!",Translation="Forwards!",Asset="rbxassetid://107708467819770",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_forwards2",Kind="Voice",Name="Fremover!",Translation="Forwards!",Asset="rbxassetid://137187543036301",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_forwards3",Kind="Voice",Name="Fremover!",Translation="Forwards!",Asset="rbxassetid://78585853267487",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_fatherland1",Kind="Voice",Name="For federlandet!",Translation="For the Fatherland!",Asset="rbxassetid://138506406832576",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_fatherland2",Kind="Voice",Name="For federlandet!",Translation="For the Fatherland!",Asset="rbxassetid://81248116269690",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale/norwegian_fatherland3",Kind="Voice",Name="For federlandet!",Translation="For the Fatherland!",Asset="rbxassetid://81813801656582",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/NorwegianMale",LanguageGroup="Norwegian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito/kaito_charge",Kind="Voice",Name="Totsugeki!",Translation="Charge!",Asset="rbxassetid://88681148053289",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito",LanguageGroup="AndouranKaito"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito/kaito_sun",Kind="Voice",Name="Taiyō e!",Translation="To the sun!",Asset="rbxassetid://77038697239196",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito",LanguageGroup="AndouranKaito"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito/kaito_roar",Kind="Voice",Name="Hoero!",Translation="Roar!",Asset="rbxassetid://135876783017310",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito",LanguageGroup="AndouranKaito"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito/kaito_victory",Kind="Voice",Name="Hisshō!",Translation="Certain victory!",Asset="rbxassetid://121121970858061",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito",LanguageGroup="AndouranKaito"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito/kaito_beautiful",Kind="Voice",Name="Utsukushiki shi!",Translation="Beautiful death!",Asset="rbxassetid://136855277151258",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito",LanguageGroup="AndouranKaito"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito/kaito_banner",Kind="Voice",Name="Hata o mamore!",Translation="Protect the banner!",Asset="rbxassetid://71748914612440",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AndouranKaito",LanguageGroup="AndouranKaito"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMarineMale/marine_charge1",Kind="Voice",Name="Forward, marines!",Translation="Forward, marines!",Asset="rbxassetid://115187331646478",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMarineMale",LanguageGroup="AmericanMarine"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMarineMale/marine_trade1",Kind="Voice",Name="Free trade and sailor's rights!",Translation="Free trade and sailor's rights!",Asset="rbxassetid://93361559894584",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMarineMale",LanguageGroup="AmericanMarine"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMarineMale/marine_trade2",Kind="Voice",Name="Free trade and sailor's rights!",Translation="Free trade and sailor's rights!",Asset="rbxassetid://94884718430894",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanMarineMale",LanguageGroup="AmericanMarine"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanRangerMale/ranger_charge",Kind="Voice",Name="Rangers, lead the way!",Translation="Rangers, lead the way!",Asset="rbxassetid://109279278065895",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/AmericanRangerMale",LanguageGroup="AmericanRanger"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_warcry1",Kind="Voice",Name="Urraaa!",Translation="Urraaa!",Asset="rbxassetid://120151251647794",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_warcry2",Kind="Voice",Name="Urrraaaahaha!",Translation="Urrraaaahaha!",Asset="rbxassetid://112551735442211",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_warcry3",Kind="Voice",Name="Urraaaaaaa!",Translation="Urraaaaaaa!",Asset="rbxassetid://126789879972113",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_forwards1",Kind="Voice",Name="Înainte, fraților!",Translation="Forward, brothers!",Asset="rbxassetid://123482936621290",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_forwards2",Kind="Voice",Name="Înainte!",Translation="Forward!",Asset="rbxassetid://108859056453027",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_forwards3",Kind="Voice",Name="Înainte, fraților!",Translation="Forward, brothers!",Asset="rbxassetid://102191534756108",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_attack1",Kind="Voice",Name="Zdrobiți-i!",Translation="Crush them!",Asset="rbxassetid://110277007613265",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_attack2",Kind="Voice",Name="La atac!",Translation="On the attack!",Asset="rbxassetid://138511678726439",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_attack3",Kind="Voice",Name="Atac!",Translation="Attack!",Asset="rbxassetid://137872851041158",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_fatherland1",Kind="Voice",Name="Pentru patrie!",Translation="For the fatherland!",Asset="rbxassetid://116941200283549",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_fatherland2",Kind="Voice",Name="Pentru patrie!",Translation="For the fatherland!",Asset="rbxassetid://128947044232378",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_fatherland3",Kind="Voice",Name="Pentru patrie!",Translation="For the fatherland!",Asset="rbxassetid://128835532682371",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_patrotic1",Kind="Voice",Name="Sultanului!",Translation="To the Sultan!",Asset="rbxassetid://117131503368814",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_patrotic2",Kind="Voice",Name="Sultanului!",Translation="To the Sultan!",Asset="rbxassetid://91240068437449",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_patrotic3",Kind="Voice",Name="Moldoveni!",Translation="Moldovans!",Asset="rbxassetid://91873003558216",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_insult2",Kind="Voice",Name="Porci fără valoare!",Translation="Worthless pigs!",Asset="rbxassetid://87100245167993",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_insult3",Kind="Voice",Name="Fugiți, lașilor!",Translation="Run, you cowards!",Asset="rbxassetid://97489643855558",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_victory1",Kind="Voice",Name="Victorie! Victorie!",Translation="Victory! Victory!",Asset="rbxassetid://83457530737210",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_victory2",Kind="Voice",Name="Noi am biruit!",Translation="We won!",Asset="rbxassetid://72321371389549",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_victory3",Kind="Voice",Name="Dumnezeu este cu noi!",Translation="God is with us!",Asset="rbxassetid://130650392803953",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_laugh1",Kind="Voice",Name="Hahahaha!",Translation="Hahahaha!",Asset="rbxassetid://117856149189301",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale/moldovan_laugh2",Kind="Voice",Name="Hahaha!",Translation="Hahaha!",Asset="rbxassetid://121836933328702",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanMoldovanMale",LanguageGroup="OttomanMoldovan"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale/sheep_1",Kind="Voice",Name="BAAAAAA!",Translation="BAAAAAA!",Asset="rbxassetid://84217689588930",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale",LanguageGroup="Sheep"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale/sheep_2",Kind="Voice",Name="BAAAAAA!",Translation="BAAAAAA!",Asset="rbxassetid://113406335550468",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale",LanguageGroup="Sheep"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale/sheep_3",Kind="Voice",Name="BAAAAAA!",Translation="BAAAAAA!",Asset="rbxassetid://131390873110219",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale",LanguageGroup="Sheep"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale/sheep_4",Kind="Voice",Name="BAAAAAA!",Translation="BAAAAAA!",Asset="rbxassetid://110608850337253",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale",LanguageGroup="Sheep"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale/sheep_5",Kind="Voice",Name="BAAAAAA!",Translation="BAAAAAA!",Asset="rbxassetid://76638921852209",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale",LanguageGroup="Sheep"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale/sheep_strange",Kind="Voice",Name="BAAAAAA?",Translation="BAAAAAA?",Asset="rbxassetid://92295365423109",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/SheepMale",LanguageGroup="Sheep"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_wesk1",Kind="Voice",Name="Seven minutes.",Translation="Seven minutes.",Asset="rbxassetid://122106648225625",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_wesk2",Kind="Voice",Name="Seven minutes is all I can spare to play NW.",Translation="Seven minutes is all I can spare to play NW.",Asset="rbxassetid://135705713318809",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_wesk3",Kind="Voice",Name="Here I am, offering you my precious time.",Translation="Here I am, offering you my precious time.",Asset="rbxassetid://114241054134103",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_chris1",Kind="Voice",Name="Hurry!",Translation="Hurry!",Asset="rbxassetid://128509330609057",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_chris2",Kind="Voice",Name="I need ammo.",Translation="I need ammo.",Asset="rbxassetid://117121156935346",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_leon1",Kind="Voice",Name="Ashley!",Translation="Ashley!",Asset="rbxassetid://111704797752943",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_leon2",Kind="Voice",Name="What are you, my mother?",Translation="What are you, my mother?",Asset="rbxassetid://101152793709347",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_leon3",Kind="Voice",Name="These people are NOT right.",Translation="These people are NOT right.",Asset="rbxassetid://115524693837263",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_alpha",Kind="Voice",Name="This is hunk from Alpha Team.",Translation="This is hunk from Alpha Team.",Asset="rbxassetid://71720364937080",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools/resident_chainsaw",Kind="Voice",Name="VRRRRBRRRRBRRRRRRRBRRRR!!!",Translation="VRRRRBRRRRBRRRRRRRBRRRR!!!",Asset="rbxassetid://89110660204111",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/ResidentFools",LanguageGroup="ResidentFools"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Duck/duck_1",Kind="Voice",Name="Quack.",Translation="Quack.",Asset="rbxassetid://119558355871902",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Duck",LanguageGroup="Duck"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Duck/duck_2",Kind="Voice",Name="Quack.",Translation="Quack.",Asset="rbxassetid://104570517959742",Gender="Shared",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/Duck",LanguageGroup="Duck"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_hoorah1",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://89201171273322",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_hoorah2",Kind="Voice",Name="Hoorah!",Translation="Hoorah!",Asset="rbxassetid://94046536843954",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_perish1",Kind="Voice",Name="Sie werden zugrunde gehen!",Translation="They shall perish!",Asset="rbxassetid://97747779453004",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_nomercy1",Kind="Voice",Name="Keine gnade!",Translation="No mercy!",Asset="rbxassetid://73702833916148",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_nomercy2",Kind="Voice",Name="Keine gnade!",Translation="No mercy!",Asset="rbxassetid://99231482614075",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_forward1",Kind="Voice",Name="Vorwärts Kameraden!",Translation="Forwards Comrades!",Asset="rbxassetid://100571738849985",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_forward2",Kind="Voice",Name="Vorwärts Kameraden!",Translation="Forwards Comrades!",Asset="rbxassetid://100715213961971",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_forwardboys1",Kind="Voice",Name="Vorwärts Junges!",Translation="Forwards Boys!",Asset="rbxassetid://127549844019536",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_forwardboys2",Kind="Voice",Name="Vorwärts Junges!",Translation="Forwards Boys!",Asset="rbxassetid://76317380701837",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_forwardboys3",Kind="Voice",Name="Vorwärts Junges!",Translation="Forwards Boys!",Asset="rbxassetid://109135719757936",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_furkaiser1",Kind="Voice",Name="Für den Kaiser!",Translation="For the Kaiser!",Asset="rbxassetid://120336751302929",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_furkaiser2",Kind="Voice",Name="Für den Kaiser!",Translation="For the Kaiser!",Asset="rbxassetid://88935872489377",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_furvaterland1",Kind="Voice",Name="Für das Vaterland!",Translation="For the Fatherland!",Asset="rbxassetid://88678867660957",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_attack1",Kind="Voice",Name="Attacke!",Translation="Attack!",Asset="rbxassetid://125888459212813",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_destroy1",Kind="Voice",Name="Vernichtet sie!",Translation="Destroy them!",Asset="rbxassetid://125591067542098",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_charge1",Kind="Voice",Name="Angriff!",Translation="Charge!",Asset="rbxassetid://75311538531656",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_charge2",Kind="Voice",Name="Angriff!",Translation="Charge!",Asset="rbxassetid://108158562738688",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale/german_follow1",Kind="Voice",Name="Folge mir junges!",Translation="Follow me boys!",Asset="rbxassetid://98465655172844",Gender="Female",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/GermanFemale",LanguageGroup="German"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_attack1",Kind="Voice",Name="Za Bosnu, naprijed!",Translation="For Bosnia, forward!",Asset="rbxassetid://85731407069405",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_attack2",Kind="Voice",Name="Drži liniju, ne popuštaj!",Translation="Hold the line, do not give in!",Asset="rbxassetid://114307898039338",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_attack3",Kind="Voice",Name="Udri, braćo, udri!",Translation="Strike, brothers, strike!",Asset="rbxassetid://100255704558780",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_patriot1",Kind="Voice",Name="Bosna stoji, Bosna traje!",Translation="Bosnia stands, Bosnia endures!",Asset="rbxassetid://87949183799764",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_patriot2",Kind="Voice",Name="Slava Bosni i našim junacima!",Translation="Glory to Bosnia and our heroes!",Asset="rbxassetid://95018719964721",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_patriot3",Kind="Voice",Name="Ne damo Bosnu nikome!",Translation="We will not give up Bosnia to anyone!",Asset="rbxassetid://140252447454372",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_patriot4",Kind="Voice",Name="Pobjeda je naša!",Translation="Victory is ours!",Asset="rbxassetid://135545679320148",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_charge1",Kind="Voice",Name="Juriš, za čast Bosne!",Translation="Charge, for the honor of Bosnia!",Asset="rbxassetid://124198129953648",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_charge2",Kind="Voice",Name="Naprijed, nema stajanja!",Translation="Forward, no stopping!",Asset="rbxassetid://99113844915808",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_charge3",Kind="Voice",Name="Za domovinu JURIŠ!",Translation="For the homeland CHARGE!",Asset="rbxassetid://70370559718869",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_cheer1",Kind="Voice",Name="Allahu ekber!",Translation="God is Great!",Asset="rbxassetid://138043728347257",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_cheer2",Kind="Voice",Name="Za Bosnu do kraja!",Translation="For Bosnia to the end!",Asset="rbxassetid://99131038175180",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_cheer3",Kind="Voice",Name="Aaaajmoooo!",Translation="Lets gooooo!",Asset="rbxassetid://116223809303218",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_laugh1",Kind="Voice",Name="Haha, bježe!",Translation="Haha, they're running!",Asset="rbxassetid://121234045458523",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_laugh2",Kind="Voice",Name="Hahahahahaaa!",Translation="Hahahahahaaa!",Asset="rbxassetid://106491266255260",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale/bosnian_laugh3",Kind="Voice",Name="Hahahahahaaa!",Translation="Hahahahahaaa!",Asset="rbxassetid://92934769161389",Gender="Male",Path="ReplicatedStorage/StartClient/CombatClient/ChantActionClient/ChantStorage/OttomanBosnianMale",LanguageGroup="OttomanBosnian"},{Id="ReplicatedStorage/LoadoutsStorage/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/NavigationTable",Lines=171},{Id="ReplicatedStorage/LoadoutsStorage/LoadoutsTable/LoadoutConvShared",Kind="Catalog",Name="LoadoutConvShared",Path="ReplicatedStorage/LoadoutsStorage/LoadoutsTable/LoadoutConvShared",Lines=13},{Id="ReplicatedStorage/LoadoutsStorage/LoadoutsTable/LoadoutConvServer",Kind="Catalog",Name="LoadoutConvServer",Path="ReplicatedStorage/LoadoutsStorage/LoadoutsTable/LoadoutConvServer",Lines=8},{Id="ReplicatedStorage/LoadoutsStorage/LoadoutsTable",Kind="Catalog",Name="LoadoutsTable",Path="ReplicatedStorage/LoadoutsStorage/LoadoutsTable",Lines=487},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/NavigationPermissions",Lines=54},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/NavigationTable",Lines=72},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/HeightTable",Lines=20},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/UniformTable",Lines=88},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun/EquipmentTable",Lines=116},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun",Kind="Catalog",Name="Fun",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Fun",Lines=597},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/EquipmentTable",Lines=124},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/HeightTable",Lines=25},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/NavigationPermissions",Lines=62},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/UniformFatigueTable",Lines=12},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/UniformGreatcoatTable",Lines=134},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/UniformTable",Lines=648},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/NavigationTable",Lines=903},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/ModelTable/ModelTexturesTable",Lines=21},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman/ModelTable",Lines=397},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman",Kind="Catalog",Name="Ottoman",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Ottoman",Lines=4189},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/NavigationTable",Lines=564},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/EquipmentTable",Lines=132},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/HeightTable",Lines=24},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/NavigationPermissions",Lines=60},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/UniformFatigueTable",Lines=16},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/UniformGreatcoatTable",Lines=49},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/ModelTable/ModelTexturesTable",Lines=5},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/ModelTable",Lines=7},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian/UniformTable",Lines=501},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian",Kind="Catalog",Name="Prussian",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Prussian",Lines=6486},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American/ModelTable/ModelTexturesTable",Lines=69},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American/ModelTable",Lines=1490},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American/NavigationTable",Lines=711},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American/HeightTable",Lines=21},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American/UniformFatigueTable",Lines=74},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American/UniformGreatcoatTable",Lines=196},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American/EquipmentTable",Lines=376},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American/NavigationPermissions",Lines=62},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American/UniformTable",Lines=898},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/American",Kind="Catalog",Name="American",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/American",Lines=5531},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/NavigationPermissions",Lines=156},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformGreatcoatTable",Lines=414},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformFatigueTable",Lines=129},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/NavigationTable/ModuleScript",Kind="Catalog",Name="ModuleScript",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/NavigationTable/ModuleScript",Lines=3},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/NavigationTable",Lines=6287},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/HeightTable",Lines=17},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/EquipmentTable/VenerationsTable",Kind="Catalog",Name="VenerationsTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/EquipmentTable/VenerationsTable",Lines=150},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/EquipmentTable",Lines=1575},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/ModelTable/ModelTexturesTable",Lines=513},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/ModelTable",Lines=26827},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/ParisUniforms",Kind="Catalog",Name="ParisUniforms",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/ParisUniforms",Lines=5},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformTable",Lines=3459},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/BardinModels",Kind="Catalog",Name="BardinModels",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/BardinModels",Lines=1159},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformForeignTable",Kind="Catalog",Name="UniformForeignTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformForeignTable",Lines=1249},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformRandomTable",Kind="Catalog",Name="UniformRandomTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/UniformRandomTable",Lines=14},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/EtatMajor",Kind="Catalog",Name="EtatMajor",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/EtatMajor",Lines=2727},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Cavalry",Kind="Catalog",Name="Cavalry",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Cavalry",Lines=1462},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/MarineImperiale",Kind="Catalog",Name="MarineImperiale",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/MarineImperiale",Lines=1666},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Etrangers",Kind="Catalog",Name="Etrangers",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Etrangers",Lines=6093},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Infanterie",Kind="Catalog",Name="Infanterie",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Infanterie",Lines=16622},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Auxilaire",Kind="Catalog",Name="Auxilaire",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Auxilaire",Lines=3313},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/GardeImperiale",Kind="Catalog",Name="GardeImperiale",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/GardeImperiale",Lines=6249},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Wip",Kind="Catalog",Name="Wip",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Wip",Lines=1242},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Bardin",Kind="Catalog",Name="Bardin",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Bardin",Lines=1604},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Italie",Kind="Catalog",Name="Italie",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Italie",Lines=6169},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Bayern",Kind="Catalog",Name="Bayern",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Bayern",Lines=11594},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Sachsen",Kind="Catalog",Name="Sachsen",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Sachsen",Lines=2494},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Warsaw",Kind="Catalog",Name="Warsaw",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French/Modules/Warsaw",Lines=1229},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/French",Kind="Catalog",Name="French",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/French",Lines=27},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/EquipmentTable/VenerationsTable",Kind="Catalog",Name="VenerationsTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/EquipmentTable/VenerationsTable",Lines=148},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/EquipmentTable",Lines=1817},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/HeightTable",Lines=32},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/NavigationPermissions",Lines=159},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/NavigationTable",Lines=2497},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/UniformTable",Lines=3082},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/UniformGreatcoatTable",Lines=1211},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/UniformFatigueTable",Lines=1078},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/ModelTable/ModelTexturesTable",Lines=161},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan/ModelTable",Lines=3923},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan",Kind="Catalog",Name="Neopolitan",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Neopolitan",Lines=30559},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/NavigationTable",Lines=1425},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/EquipmentTable",Lines=1246},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/HeightTable",Lines=21},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/NavigationPermissions",Lines=96},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/UniformFatigueTable",Lines=442},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/UniformGreatcoatTable",Lines=580},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/UniformTable",Lines=2150},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/ModelTable/ModelTexturesTable",Lines=165},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran/ModelTable",Lines=8237},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran",Kind="Catalog",Name="Andouran",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Andouran",Lines=13553},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/EquipmentTable/VenerationsTable",Kind="Catalog",Name="VenerationsTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/EquipmentTable/VenerationsTable",Lines=16},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/EquipmentTable",Lines=779},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/HeightTable",Lines=21},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/NavigationPermissions",Lines=128},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/NavigationTable",Lines=2647},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/UniformFatigueTable",Lines=45},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/UniformGreatcoatTable",Lines=239},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/UniformTable",Lines=1791},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/ModelTable/ModelTexturesTable",Lines=42},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/ModelTable",Lines=680},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Erste",Kind="Catalog",Name="Erste",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Erste",Lines=2349},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Zweite",Kind="Catalog",Name="Zweite",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Zweite",Lines=2296},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Dritte",Kind="Catalog",Name="Dritte",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Dritte",Lines=2336},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Vierte",Kind="Catalog",Name="Vierte",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Vierte",Lines=5265},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Funfte",Kind="Catalog",Name="Funfte",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Funfte",Lines=2250},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Ungarische",Kind="Catalog",Name="Ungarische",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Ungarische",Lines=5388},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Auxiliary",Kind="Catalog",Name="Auxiliary",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Auxiliary",Lines=2658},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Teutons",Kind="Catalog",Name="Teutons",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Teutons",Lines=724},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Landwehr",Kind="Catalog",Name="Landwehr",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Landwehr",Lines=433},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/BLANK",Kind="Catalog",Name="BLANK",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/BLANK",Lines=12},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Misc",Kind="Catalog",Name="Misc",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Misc",Lines=374},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Navy",Kind="Catalog",Name="Navy",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian/Modules/Navy",Lines=343},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian",Kind="Catalog",Name="Austrian",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Austrian",Lines=1044},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/HeightTable",Lines=23},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/UniformFatigueTable",Lines=94},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/NavigationPermissions",Lines=254},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/NavigationTable",Lines=3758},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/ModelTable/ModelTexturesTable",Lines=324},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/ModelTable",Lines=5526},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/UniformTable",Lines=3092},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/UniformGreatcoatTable",Lines=930},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/EquipmentTable",Lines=1026},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/Modules/Occidentis",Kind="Catalog",Name="Occidentis",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/Modules/Occidentis",Lines=15054},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British/Modules/Orientis",Kind="Catalog",Name="Orientis",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British/Modules/Orientis",Lines=9438},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/British",Kind="Catalog",Name="British",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/British",Lines=3456},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/HeightTable",Lines=20},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/UniformFatigueTable",Lines=120},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/NavigationPermissions",Lines=126},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/UniformTable",Lines=1414},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/EquipmentTable",Lines=1103},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/UniformGreatcoatTable",Lines=365},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/ModelTable/ModelTexturesTable",Lines=202},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/ModelTable",Lines=1614},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian/NavigationTable",Lines=1626},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian",Kind="Catalog",Name="Russian",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Russian",Lines=24257},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/EquipmentTable",Kind="Catalog",Name="EquipmentTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/EquipmentTable",Lines=958},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/NavigationPermissions",Lines=74},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/UniformGreatcoatTable",Kind="Catalog",Name="UniformGreatcoatTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/UniformGreatcoatTable",Lines=229},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/UniformFatigueTable",Kind="Catalog",Name="UniformFatigueTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/UniformFatigueTable",Lines=177},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/NavigationTable",Lines=2802},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/HeightTable",Kind="Catalog",Name="HeightTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/HeightTable",Lines=16},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/UniformTable",Kind="Catalog",Name="UniformTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/UniformTable",Lines=2263},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/ModelTable/ModelTexturesTable",Kind="Catalog",Name="ModelTexturesTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/ModelTable/ModelTexturesTable",Lines=214},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/ModelTable",Kind="Catalog",Name="ModelTable",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon/ModelTable",Lines=3800},{Id="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon",Kind="Catalog",Name="Bourbon",Path="ReplicatedStorage/LoadoutsStorage/Loadouts/Bourbon",Lines=28679},{Id="ReplicatedStorage/FanionsInfoStorage/FanionsTable",Kind="Catalog",Name="FanionsTable",Path="ReplicatedStorage/FanionsInfoStorage/FanionsTable",Lines=26},{Id="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/French/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/French/NavigationTable",Lines=89},{Id="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/French/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/French/NavigationPermissions",Lines=25},{Id="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/French",Kind="Catalog",Name="French",Path="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/French",Lines=915},{Id="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/Neopolitan/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/Neopolitan/NavigationTable",Lines=102},{Id="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/Neopolitan/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/Neopolitan/NavigationPermissions",Lines=37},{Id="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/Neopolitan/FanionTextureTable",Kind="Catalog",Name="FanionTextureTable",Path="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/Neopolitan/FanionTextureTable",Lines=5},{Id="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/Neopolitan",Kind="Catalog",Name="Neopolitan",Path="ReplicatedStorage/FanionsInfoStorage/NationFanionsInfo/Neopolitan",Lines=681},{Id="ReplicatedStorage/NationsInfo/CompanyIconsTable",Kind="Catalog",Name="CompanyIconsTable",Path="ReplicatedStorage/NationsInfo/CompanyIconsTable",Lines=63},{Id="ReplicatedStorage/NationsInfo/NationTagsTable",Kind="Catalog",Name="NationTagsTable",Path="ReplicatedStorage/NationsInfo/NationTagsTable",Lines=37},{Id="ReplicatedStorage/NationsInfo/NationTeamsTable",Kind="Catalog",Name="NationTeamsTable",Path="ReplicatedStorage/NationsInfo/NationTeamsTable",Lines=22},{Id="ReplicatedStorage/NationsInfo/NationLookupTable",Kind="Catalog",Name="NationLookupTable",Path="ReplicatedStorage/NationsInfo/NationLookupTable",Lines=85},{Id="ReplicatedStorage/NationsInfo/NationWeaponsTable",Kind="Catalog",Name="NationWeaponsTable",Path="ReplicatedStorage/NationsInfo/NationWeaponsTable",Lines=31},{Id="ReplicatedStorage/NationsInfo/NationHorseStylesTable",Kind="Catalog",Name="NationHorseStylesTable",Path="ReplicatedStorage/NationsInfo/NationHorseStylesTable",Lines=20},{Id="ReplicatedStorage/NationsInfo/NationMedalsTable",Kind="Catalog",Name="NationMedalsTable",Path="ReplicatedStorage/NationsInfo/NationMedalsTable",Lines=71},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Ottoman",Kind="Catalog",Name="Ottoman",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Ottoman",Lines=138},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Prussian",Kind="Catalog",Name="Prussian",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Prussian",Lines=107},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/American",Kind="Catalog",Name="American",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/American",Lines=100},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/French",Kind="Catalog",Name="French",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/French",Lines=567},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Neopolitan",Kind="Catalog",Name="Neopolitan",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Neopolitan",Lines=609},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Andouran",Kind="Catalog",Name="Andouran",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Andouran",Lines=606},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Austrian",Kind="Catalog",Name="Austrian",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Austrian",Lines=404},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/British",Kind="Catalog",Name="British",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/British",Lines=718},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Russian",Kind="Catalog",Name="Russian",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Russian",Lines=404},{Id="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Bourbon",Kind="Catalog",Name="Bourbon",Path="ReplicatedStorage/NationsInfo/NationsWeaponsInfo/Bourbon",Lines=345},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Ottoman",Kind="Catalog",Name="Ottoman",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Ottoman",Lines=29},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Prussian",Kind="Catalog",Name="Prussian",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Prussian",Lines=16},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/American",Kind="Catalog",Name="American",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/American",Lines=49},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/French",Kind="Catalog",Name="French",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/French",Lines=155},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Neopolitan",Kind="Catalog",Name="Neopolitan",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Neopolitan",Lines=199},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Andouran",Kind="Catalog",Name="Andouran",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Andouran",Lines=70},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Austrian",Kind="Catalog",Name="Austrian",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Austrian",Lines=45},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/British",Kind="Catalog",Name="British",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/British",Lines=34},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Russian",Kind="Catalog",Name="Russian",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Russian",Lines=156},{Id="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Bourbon",Kind="Catalog",Name="Bourbon",Path="ReplicatedStorage/NationsInfo/NationsHorseStylesInfo/Bourbon",Lines=111},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/Ottoman",Kind="Catalog",Name="Ottoman",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/Ottoman",Lines=61},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/Prussian",Kind="Catalog",Name="Prussian",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/Prussian",Lines=88},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/American",Kind="Catalog",Name="American",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/American",Lines=96},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/French",Kind="Catalog",Name="French",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/French",Lines=233},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/Neopolitan",Kind="Catalog",Name="Neopolitan",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/Neopolitan",Lines=129},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/Andouran",Kind="Catalog",Name="Andouran",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/Andouran",Lines=116},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/Austrian",Kind="Catalog",Name="Austrian",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/Austrian",Lines=130},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/British",Kind="Catalog",Name="British",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/British",Lines=122},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/Russian",Kind="Catalog",Name="Russian",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/Russian",Lines=161},{Id="ReplicatedStorage/NationsInfo/NationsTeamInfo/Bourbon",Kind="Catalog",Name="Bourbon",Path="ReplicatedStorage/NationsInfo/NationsTeamInfo/Bourbon",Lines=98},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/Ottoman",Kind="Catalog",Name="Ottoman",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/Ottoman",Lines=115},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/Prussian",Kind="Catalog",Name="Prussian",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/Prussian",Lines=136},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/American",Kind="Catalog",Name="American",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/American",Lines=139},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/French",Kind="Catalog",Name="French",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/French",Lines=283},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/Neopolitan",Kind="Catalog",Name="Neopolitan",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/Neopolitan",Lines=253},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/Andouran",Kind="Catalog",Name="Andouran",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/Andouran",Lines=323},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/Austrian",Kind="Catalog",Name="Austrian",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/Austrian",Lines=170},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/British",Kind="Catalog",Name="British",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/British",Lines=154},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/Russian",Kind="Catalog",Name="Russian",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/Russian",Lines=179},{Id="ReplicatedStorage/NationsInfo/NationsTagInfo/Bourbon",Kind="Catalog",Name="Bourbon",Path="ReplicatedStorage/NationsInfo/NationsTagInfo/Bourbon",Lines=140},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Ottoman",Kind="Catalog",Name="Ottoman",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Ottoman",Lines=313},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Prussian",Kind="Catalog",Name="Prussian",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Prussian",Lines=428},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/American",Kind="Catalog",Name="American",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/American",Lines=609},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/French",Kind="Catalog",Name="French",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/French",Lines=844},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Neopolitan",Kind="Catalog",Name="Neopolitan",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Neopolitan",Lines=491},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Andouran",Kind="Catalog",Name="Andouran",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Andouran",Lines=506},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Austrian",Kind="Catalog",Name="Austrian",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Austrian",Lines=709},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/British",Kind="Catalog",Name="British",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/British",Lines=722},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Russian",Kind="Catalog",Name="Russian",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Russian",Lines=730},{Id="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Bourbon",Kind="Catalog",Name="Bourbon",Path="ReplicatedStorage/NationsInfo/NationsMedalsInfo/Bourbon",Lines=507},{Id="ReplicatedStorage/FlagsInfoStorage/FlagsTable",Kind="Catalog",Name="FlagsTable",Path="ReplicatedStorage/FlagsInfoStorage/FlagsTable",Lines=23},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Ottoman/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Ottoman/NavigationTable",Lines=238},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Ottoman/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Ottoman/NavigationPermissions",Lines=66},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Ottoman",Kind="Catalog",Name="Ottoman",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Ottoman",Lines=682},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Prussian/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Prussian/NavigationTable",Lines=77},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Prussian/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Prussian/NavigationPermissions",Lines=31},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Prussian",Kind="Catalog",Name="Prussian",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Prussian",Lines=718},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/American/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/American/NavigationPermissions",Lines=40},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/American/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/American/NavigationTable",Lines=166},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/American",Kind="Catalog",Name="American",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/American",Lines=1491},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/French/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/French/NavigationTable",Lines=401},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/French/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/French/NavigationPermissions",Lines=63},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/French",Kind="Catalog",Name="French",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/French",Lines=3442},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Neopolitan/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Neopolitan/NavigationTable",Lines=549},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Neopolitan/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Neopolitan/NavigationPermissions",Lines=47},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Neopolitan/FlagTextureTable",Kind="Catalog",Name="FlagTextureTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Neopolitan/FlagTextureTable",Lines=602},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Neopolitan",Kind="Catalog",Name="Neopolitan",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Neopolitan",Lines=2807},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Andouran/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Andouran/NavigationTable",Lines=254},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Andouran/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Andouran/NavigationPermissions",Lines=50},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Andouran",Kind="Catalog",Name="Andouran",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Andouran",Lines=2825},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Austrian/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Austrian/NavigationPermissions",Lines=76},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Austrian/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Austrian/NavigationTable",Lines=177},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Austrian",Kind="Catalog",Name="Austrian",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Austrian",Lines=1460},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/British/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/British/NavigationPermissions",Lines=177},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/British/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/British/NavigationTable",Lines=323},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/British",Kind="Catalog",Name="British",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/British",Lines=2271},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Russian/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Russian/NavigationTable",Lines=513},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Russian/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Russian/NavigationPermissions",Lines=61},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Russian",Kind="Catalog",Name="Russian",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Russian",Lines=2230},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Bourbon/NavigationTable",Kind="Catalog",Name="NavigationTable",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Bourbon/NavigationTable",Lines=159},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Bourbon/NavigationPermissions",Kind="Catalog",Name="NavigationPermissions",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Bourbon/NavigationPermissions",Lines=27},{Id="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Bourbon",Kind="Catalog",Name="Bourbon",Path="ReplicatedStorage/FlagsInfoStorage/NationFlagsInfo/Bourbon",Lines=2342}}}end function init.k()local v=init.cache.k if not v then v={c=__modImpl()}init.cache.k=v end return v.c end end do local __modImpl=function()

local Data=init.k()
local Catalog,
kinds={Snapshot=Data.Snapshot,Rows=Data.Rows,ById={},Kinds={"All"}},{}
for _,row in Catalog.Rows do
assert(not Catalog.ById[row.Id],"duplicate catalog identifier")
row.SearchText=(row.Name.." "..row.Path.." "..(row.Translation or"").." "..(row.Gender or"")):lower()
Catalog.ById[row.Id]=row
if not kinds[row.Kind]then kinds[row.Kind]=true table.insert(Catalog.Kinds,row.Kind)end
end

function Catalog.Search(query,kind,limit)
query=tostring(query or""):lower()
local result={}
limit=math.clamp(limit or 100,1,500)
for _,row in Catalog.Rows do
local match=not kind or row.Kind==kind
for token in query:gmatch"%S+"do
if not row.SearchText:find(token,1,true)then match=false break end
end
if match then table.insert(result,row)if#result>=limit then break end end
end
return result
end

function Catalog.Page(query,kind,page,pageSize)
query=tostring(query or""):lower()
pageSize=type(pageSize)=="number"and pageSize==pageSize and math.clamp(math.floor(pageSize),1,100)or 50
page=type(page)=="number"and page==page and math.max(1,math.floor(page))or 1
local matches={}
for _,row in Catalog.Rows do
local found=not kind or row.Kind==kind
for token in query:gmatch"%S+"do
if not row.SearchText:find(token,1,true)then found=false break end
end
if found then table.insert(matches,row)end
end
local pages=math.max(1,math.ceil(#matches/pageSize))
page=math.min(page,pages)
local result={}
for index=(page-1)*pageSize+1,math.min(page*pageSize,#matches)do
table.insert(result,matches[index])
end
return result,{Page=page,Pages=pages,Total=#matches,PageSize=pageSize}
end

function Catalog.Validate()
local errors={}
for _,row in Catalog.Rows do
if row.Kind=="Voice"and(not row.Asset:match"^rbxassetid://%d+$"or row.Name=="")then
table.insert(errors,row.Id)
end
end
return#errors==0,errors
end

return Catalog end function init.l()local v=init.cache.l if not v then v={c=__modImpl()}init.cache.l=v end return v.c end end do local __modImpl=function()

local Scope,
Runtime,
Audio=init.a(),init.b(),{Volume=0.5,MaxVoices=8,Voices={},Categories={Preview=1,UI=1},Preview=nil}
local Owned,
feedbackGeneration,
sequence,
voiceOrder,
endings=Scope.new"audio",0,0,{},{}

function Audio.SetUIFeedback(enabled)
feedbackGeneration=feedbackGeneration+1
local generation=feedbackGeneration
Audio.UIAsset=nil
if not enabled then return true end
local entry=init.d()["bubble.wav"]
local asset,err=init.f().Get("84e Client/assets/bubble.wav",entry.URL)
if generation~=feedbackGeneration or not Runtime.Alive then return false,"audio request cancelled"end
if not asset then return false,err end
Audio.UIAsset=asset
return true
end

function Audio.Remove(sound)
if not Audio.Voices[sound]then return end
Audio.Voices[sound]=nil
voiceOrder[sound]=nil
if endings[sound]then Owned:Release(endings[sound],true)endings[sound]=nil end
if Audio.Preview==sound then Audio.Preview=nil end
Owned:Release(sound,true)
end

function Audio.StopPreview()
if Audio.Preview then Audio.Remove(Audio.Preview)end
end

function Audio.SetVolume(value)
if type(value)~="number"or value~=value then return false end
Audio.Volume=math.clamp(value,0,1)
for sound,category in Audio.Voices do
sound.Volume=Audio.Volume*math.clamp(Audio.Categories[category]or 1,0,1)
end
return true
end

function Audio.SetMaxVoices(value)
if type(value)~="number"or value~=value then return false end
Audio.MaxVoices=math.clamp(math.floor(value),1,16)
local active={}
for sound in Audio.Voices do if sound~=Audio.Preview then table.insert(active,sound)end end
table.sort(active,function(a,b)return(voiceOrder[a]or 0)<(voiceOrder[b]or 0)end)
if Audio.Preview then table.insert(active,Audio.Preview)end
while#active>Audio.MaxVoices do Audio.Remove(table.remove(active,1))end
return true
end

function Audio.SetCategory(name,value)
if not Audio.Categories[name]or type(value)~="number"or value~=value then return false end
Audio.Categories[name]=math.clamp(value,0,1)
Audio.SetVolume(Audio.Volume)
return true
end

function Audio.Play(asset,category,duration)
if not Runtime.Alive then return false,"session stopped"end
if type(asset)~="string"or#asset==0 or#asset>1024 or not Audio.Categories[category]then return false,"invalid audio request"end
local count=0
for _ in Audio.Voices do count=count+1 end
if count>=Audio.MaxVoices then return false,"audio voice limit reached"end
local sound
local ok,err=pcall(function()
sound=Owned:Own(Instance.new"Sound")
sound.SoundId=asset
sound.Volume=math.clamp(Audio.Volume,0,1)*math.clamp(Audio.Categories[category],0,1)
sound.Parent=game:GetService"SoundService"
Audio.Voices[sound]=category
sequence=sequence+1 voiceOrder[sound]=sequence
endings[sound]=Owned:Own(sound.Ended:Connect(function()Audio.Remove(sound)end))
sound:Play()
Owned:Delay(math.clamp(duration or 5,0.1,15),function()Audio.Remove(sound)end)
end)
if not ok then
if sound then Audio.Voices[sound]=true Audio.Remove(sound)end
Runtime.Record("audio preview",err)
return false,tostring(err)
end
return true,sound
end

function Audio.PreviewAsset(asset)
Audio.StopPreview()
local ok,sound=Audio.Play(asset,"Preview",5)
if ok then Audio.Preview=sound end
return ok,sound
end

function Audio.Stop()
feedbackGeneration=feedbackGeneration+1
Audio.UIAsset=nil
Audio.Preview=nil
table.clear(Audio.Voices)
table.clear(voiceOrder)
table.clear(endings)
Owned:Stop()
end

Runtime.Add(Audio.Stop)
return Audio end function init.m()local v=init.cache.m if not v then v={c=__modImpl()}init.cache.m=v end return v.c end end do local __modImpl=function()

local Runtime,
Storage,
Preflight,
Navigation,
Catalog,
Audio,
Assets,
HttpService,
Panels=init.b(),init.c(),init.g(),init.h(),init.l(),init.m(),init.f(),game:GetService"HttpService",{}

function Panels.Build(library,window,manager,context)
context=context or{}
local options,
tools,
diagnostics,
content,report=getgenv().Options,window:AddTab"Tools",window:AddTab"Diagnostics",window:AddTab"Content",function(
ok, err)
library:Notify(ok and"Completed"or Runtime.Sanitize(err or"operation failed"))end local export, 









status=function(name, data)local ok,payload=pcall(function()return HttpService:JSONEncode(data)end)if not ok then return report(false,payload)end local made,err=Storage.MakeFolders"84e Client/reports"if not made then return report(false,err)end report(Storage.Write("84e Client/reports/"..name..".json",payload))end, diagnostics:AddLeftGroupbox"Compatibility"
local statusLabel=status:AddLabel("",true)local refreshStatus=function()

local description=Preflight.Describe()
statusLabel:SetText(description..(context.InitializationError and"\nInitialization: "..Runtime.Sanitize(context.InitializationError)or""))end

status:AddButton("Refresh readiness",refreshStatus)
status:AddButton("Export readiness",function()
local ready,rows=Preflight.Check()
export("readiness",{Version=Preflight.Version,Snapshot=Preflight.Snapshot,Ready=ready,Executor=Preflight.Executor(),Capabilities=rows})
end)
refreshStatus()

local errors=diagnostics:AddRightGroupbox"Diagnostics and recovery"
local metricLabel,
logLabel=errors:AddLabel("Select a component",true),errors:AddLabel("No recorded errors",true)local showMetric=function(
name)
local metric=name and Runtime.Metrics[name]
if not metric then return metricLabel:SetText"No component selected"end
local p95=0
for _,row in Runtime.Snapshot().Components do if row.Name==name then p95=row.P95Ms break end end
metricLabel:SetText(string.format("%s\n%s | updates %d\nlast %.3f ms | p95 %.3f ms | max %.3f ms\nOwned resources: %d",
name,metric.Suspended and"SUSPENDED"or"ACTIVE",metric.Count,metric.LastMs,p95,metric.MaxMs,Runtime.Resources:Count()))end

errors:AddDropdown("App_Component",{Text="Component",Values={},AllowNull=true,Callback=showMetric})local refreshDiagnostics=function()

local names,logs={},{}
for name in Runtime.Metrics do table.insert(names,name)end
table.sort(names)options.App_Component:SetValues(names)
showMetric(options.App_Component.Value)
for index=math.max(1,#Runtime.Log-4),#Runtime.Log do
local row=Runtime.Log[index]
table.insert(logs,row.Name.." x"..row.Count..": "..row.Message:sub(1,160))
end
logLabel:SetText(#logs>0 and table.concat(logs,"\n")or"No recorded errors")end

errors:AddButton("Refresh diagnostics",refreshDiagnostics)
errors:AddButton("Retry selected component",function()report(Runtime.Recover(options.App_Component.Value))end)
errors:AddButton("Export local diagnostics",function()export("diagnostics",Runtime.Snapshot())end)
errors:AddButton("Copy diagnostics",function()
if type(setclipboard)~="function"then return report(false,"clipboard unavailable")end
local ok,err=pcall(function()setclipboard(HttpService:JSONEncode(Runtime.Snapshot()))end)
report(ok,err)
end)
refreshDiagnostics()

local search=tools:AddLeftGroupbox"Find and reset settings"
local selectedLabel=search:AddLabel("Select a result",true)
search:AddInput("App_Search",{Text="Search settings",Default="",Callback=function(value)
local results={}
for _,row in Navigation.Search(value)do if#results>=100 then break end table.insert(results,row.Id)end
if options.App_SearchResult then options.App_SearchResult:SetValues(results)end
end})
search:AddDropdown("App_SearchResult",{Text="Result",Values={},AllowNull=true,Callback=function(id)
local row=id and Navigation.Entries[id]
selectedLabel:SetText(row and(row.Label.."\n"..row.Type.." | "..(row.Tab and row.Tab.Name or"addon"))or"Select a result")
end})
search:AddButton("Reveal selected setting",function()report(Navigation.Focus(options.App_SearchResult.Value))end)
search:AddButton("Reset selected setting",function()report(Navigation.Reset(options.App_SearchResult.Value))end)
search:AddButton("Reset selected tab",function()
local row=Navigation.Entries[options.App_SearchResult.Value]
if not row or not row.Tab then return report(false,"select a setting with a tab")end
local ok,failed=Navigation.ResetTab(row.Tab)
report(ok,table.concat(failed,"\n"))
end)
local conflictLabel=search:AddLabel("No keybind conflicts checked",true)
search:AddButton("Check keybind conflicts",function()
local conflicts=Navigation.Conflicts()
conflictLabel:SetText(#conflicts>0 and table.concat(conflicts,"\n")or"No active keybind conflicts")
end)

local access=tools:AddRightGroupbox"Accessibility"
access:AddSlider("App_UIScale",{Text="UI scale",Default=1,Min=0.75,Max=1.5,Rounding=2,Callback=function(value)
if library.ScaleControl then library.ScaleControl.Scale=value end
end})
access:AddSlider("App_TextScale",{Text="Text scale",Default=1,Min=0.8,Max=1.5,Rounding=2,Callback=function(value)library:SetTextScale(value)end})
access:AddToggle("App_ReducedMotion",{Text="Reduced motion",Default=false,Callback=function(value)
library.ReducedMotion=value
if value and library.MenuBlur then library.MenuBlur.Enabled=false end
end})
access:AddToggle("App_StandardCursor",{Text="Use standard cursor",Default=true,Callback=function(value)
library.StandardCursor=value
if value and library.OriginalMouseIconEnabled~=nil then game:GetService"UserInputService".MouseIconEnabled=library.OriginalMouseIconEnabled end
end})
access:AddLabel("Tab: next setting\nArrows: adjust | Enter: activate\nTyping keeps game binds inactive",true)
local contrastBaseline
access:AddDropdown("App_Contrast",{Text="Contrast preset",Values={"Default","High contrast"},Default="Default",Callback=function(value)
if value=="High contrast"then
if not contrastBaseline then
contrastBaseline={}
for _,key in{"BackgroundColor","MainColor","FontColor","OutlineColor","AccentColor"}do contrastBaseline[key]=library[key]end
end
library.BackgroundColor=Color3.fromRGB(8,8,8)library.MainColor=Color3.fromRGB(20,20,20)
library.FontColor=Color3.fromRGB(255,255,255)library.OutlineColor=Color3.fromRGB(170,170,170)
library.AccentColor=Color3.fromRGB(255,210,0)
elseif contrastBaseline then
for key,color in contrastBaseline do library[key]=color end
contrastBaseline=nil
end
library:UpdateColorsUsingRegistry()
end})

local profiles=tools:AddLeftGroupbox"Profile management"
profiles:AddInput("App_ProfileSource",{Text="Source profile",Default=""})
profiles:AddInput("App_ProfileDestination",{Text="New profile name",Default=""})
profiles:AddInput("App_ProfileJSON",{Text="Import JSON",Default=""})
local previewLabel,sourceName=profiles:AddLabel("Preview before loading",true),function()
return options.App_ProfileSource.Value end
profiles:AddButton("Preview selected profile",function()
local ok,data=manager:ReadDocument(sourceName())
if not ok then return report(false,data)end
local valid,preview=manager:Preview(data)
if not valid then return report(false,preview)end
previewLabel:SetText("Changed: "..#preview.Changed.." | skipped: "..#preview.Skipped.." | constrained: "..#preview.Constrained.."\n"..table.concat(preview.Changed,", "):sub(1,700))
end)
profiles:AddButton("Load selected profile",function()report(manager:Load(sourceName()))end)
profiles:AddButton("Duplicate profile",function()report(manager:Duplicate(sourceName(),options.App_ProfileDestination.Value))end)
profiles:AddButton("Rename profile",function()report(manager:Rename(sourceName(),options.App_ProfileDestination.Value))end)
profiles:AddButton{Text="Delete profile",DoubleClick=true,Func=function()report(manager:Delete(sourceName()))end}
profiles:AddButton("Recover backup as new profile",function()report(manager:RecoverBackup(sourceName()))end)
profiles:AddButton("Import as new profile",function()report(manager:Import(options.App_ProfileDestination.Value,options.App_ProfileJSON.Value))end)
profiles:AddButton("Export selected profile",function()
local ok,payload=manager:Export(sourceName())
if not ok then return report(false,payload)end
if type(setclipboard)=="function"then report(pcall(setclipboard,payload))
else options.App_ProfileJSON:SetValue(payload)library:Notify"Export copied into JSON field"end
end)

if context.World then
local world,
visual=context.World,tools:AddRightGroupbox"Visual ownership and preview"
library:OnUnload(function()
if not manager.Previewing then return end
world.CancelPreview()
if context.SyncWorld then context.SyncWorld()end
manager.Previewing=false
local ok,err=manager:Save()
if not ok then Runtime.Record("preview cancel save",err)end
end)
visual:AddLabel("Only selected properties are overridden.\nUnselected settings follow the game.",true)
visual:AddToggle("App_ClearAtmosphere",{Text="Clear atmospheric haze",Default=false,Callback=function(value)world.ClearAtmosphere=value end})
visual:AddButton("Begin visual preview",function()
if manager.Previewing then return end
local saved,err=manager:Flush()
if not saved then report(false,err)return end
manager.Previewing=true
manager:InvalidateQueue()
world.BeginPreview()
end)
visual:AddButton("Apply visual preview",function()
world.ApplyPreview()
manager.Previewing=false
library:AttemptSave()
end)
visual:AddButton("Cancel visual preview",function()
world.CancelPreview()
if context.SyncWorld then context.SyncWorld()end
manager.Previewing=false
library:AttemptSave()
end)
end

local budget=tools:AddRightGroupbox"Visual and audio budgets"
budget:AddDropdown("App_Quality",{Text="Cosmetic quality",Values={"Low","Medium","High"},Default="Medium",Callback=function(value)
local limits={Low={32,4},Medium={128,8},High={256,16}}
local chosen=limits[value]or limits.Medium
Audio.SetMaxVoices(chosen[2])
if context.Tracers then context.Tracers.Config.MaxSegments=chosen[1]end
end})
budget:AddSlider("App_PreviewVolume",{Text="Preview master volume",Default=50,Min=0,Max=100,Rounding=0,Callback=function(value)Audio.SetVolume(value/100)end})
budget:AddSlider("App_UIAudioVolume",{Text="UI sound category",Default=100,Min=0,Max=100,Rounding=0,Callback=function(value)Audio.SetCategory("UI",value/100)end})
budget:AddToggle("App_UIFeedback",{Text="Enable UI click sound",Default=false,Callback=function(value)
local ok,err=Audio.SetUIFeedback(value)
if not ok then report(false,err)end
end})
library:GiveSignal(game:GetService"UserInputService".InputEnded:Connect(function(input)
if not library.MenuVisible or not Audio.UIAsset or not window.Outer then return end
if input.UserInputType~=Enum.UserInputType.MouseButton1 and input.UserInputType~=Enum.UserInputType.Touch then return end
local position=game:GetService"UserInputService":GetMouseLocation()
if input.UserInputType==Enum.UserInputType.Touch then position=input.Position end
local origin,size=window.Outer.AbsolutePosition,window.Outer.AbsoluteSize
if position.X>=origin.X and position.Y>=origin.Y and position.X<=origin.X+size.X and position.Y<=origin.Y+size.Y then
Audio.Play(Audio.UIAsset,"UI",1)
end
end))

local browser=content:AddLeftGroupbox"Read-only game content"
browser:AddLabel(Catalog.Snapshot.."\nCatalog metadata is offline; asset availability can vary.",true)
local rowMap,
detail,
page,queryText,
pageLabel,kind={},browser:AddLabel("Select content to inspect",true),1,"",(browser:AddLabel("",true))local refreshContent=function(
query)
if query~=nil then queryText=query page=1 end
table.clear(rowMap)
local values,
rows,info={},Catalog.Page(queryText,kind,page,50)
page=info.Page
pageLabel:SetText(string.format("Page %d / %d | %d matches",info.Page,info.Pages,info.Total))
for index,row in rows do
local label=index..". "..row.Name..(row.Gender and(" / "..row.LanguageGroup.." / "..row.Gender)or" / Catalog")
rowMap[label]=row table.insert(values,label)
end
if options.App_ContentResult then options.App_ContentResult:SetValues(values)end end

browser:AddDropdown("App_ContentKind",{Text="Content type",Values=Catalog.Kinds,Default="All",Callback=function(value)
kind=value~="All"and value or nil
page=1 refreshContent()
end})
browser:AddButton("Previous page",function()page=math.max(1,page-1)refreshContent()end)
browser:AddButton("Next page",function()page=page+1 refreshContent()end)
browser:AddInput("App_ContentSearch",{Text="Search content",Default="",Callback=refreshContent})
browser:AddDropdown("App_ContentResult",{Text="Content",Values={},AllowNull=true,Callback=function(value)
local row=rowMap[value]
detail:SetText(row and(row.Name.."\n"..(row.Translation or row.Kind).."\n"..row.Path)or"Select content")
end})
browser:AddButton("Preview selected voice",function()
local row=rowMap[options.App_ContentResult.Value]
if not row or row.Kind~="Voice"then return report(false,"select a voice entry")end
report(Audio.PreviewAsset(row.Asset))
end)
browser:AddButton("Stop audio preview",Audio.StopPreview)
refreshContent""

local localMedia=content:AddRightGroupbox"Local asset library"
localMedia:AddInput("App_LocalWAV",{Text="Managed WAV filename",Default=""})
localMedia:AddLabel("Place custom WAV files under\n84e Client/assets/\nOnly verified WAV headers are accepted.",true)
localMedia:AddButton("Preview local WAV",function()
local asset,err=Assets.Get("84e Client/assets/"..options.App_LocalWAV.Value)
if not asset then return report(false,err)end
report(Audio.PreviewAsset(asset))
end)
localMedia:AddButton("Retry selected local asset",function()report(Assets.Invalidate("84e Client/assets/"..options.App_LocalWAV.Value,false))end)
localMedia:AddButton("Validate content catalog",function()
local ok,failures=Catalog.Validate()
report(ok,table.concat(failures,", "))
end)

manager:SetIgnoreIndexes{"App_Component","App_Search","App_SearchResult","App_ProfileSource","App_ProfileDestination","App_ProfileJSON","App_ContentKind","App_ContentSearch","App_ContentResult","App_LocalWAV"}
library:GiveSignal(game:GetService"UserInputService".InputBegan:Connect(function(input,processed)
if processed or library.CapturingInput or not library.MenuVisible or game:GetService"UserInputService":GetFocusedTextBox()then return end
if input.KeyCode==Enum.KeyCode.Tab then Navigation.Step(1)
elseif input.KeyCode==Enum.KeyCode.Left then Navigation.Activate(-1)
elseif input.KeyCode==Enum.KeyCode.Right then Navigation.Activate(1)
elseif input.KeyCode==Enum.KeyCode.Return then Navigation.Activate(1)
elseif input.KeyCode==Enum.KeyCode.Escape then library:ClosePopups()end
end))
end

return Panels end function init.n()local v=init.cache.n if not v then v={c=__modImpl()}init.cache.n=v end return v.c end end do local __modImpl=function()


local HttpService,
Storage,
SaveManager,
Options,
Toggles=game:GetService"HttpService",init.c(),{Folder="84e Client",Ignore={},ActiveProfile=nil,Loading=false,Dirty=false,Generation=0,LastReport=nil},getgenv().Options,getgenv().Toggles

SaveManager.Parser={
Toggle={
Save=function(idx,object)return{type="Toggle",idx=idx,value=object.Value}end,
Load=function(idx,data)if Toggles[idx]then Toggles[idx]:SetValue(data.value)end end,
},
Slider={
Save=function(idx,object)return{type="Slider",idx=idx,value=object.Value}end,
Load=function(idx,data)if Options[idx]then Options[idx]:SetValue(data.value)end end,
},
Dropdown={
Save=function(idx,object)return{type="Dropdown",idx=idx,value=object.Value,multi=object.Multi==true}end,
Load=function(idx,data)if Options[idx]then Options[idx]:SetValue(data.value)end end,
},
ColorPicker={
Save=function(idx,object)return{type="ColorPicker",idx=idx,value=object.Value:ToHex(),transparency=object.Transparency}end,
Load=function(idx,data)if Options[idx]then Options[idx]:SetValueRGB(Color3.fromHex(data.value),data.transparency)end end,
},
KeyPicker={
Save=function(idx,object)return{type="KeyPicker",idx=idx,mode=object.Mode,key=object.Value}end,
Load=function(idx,data)if Options[idx]then Options[idx]:SetValue{data.key,data.mode}end end,
},
Input={
Save=function(idx,object)return{type="Input",idx=idx,text=object.Value}end,
Load=function(idx,data)if Options[idx]then Options[idx]:SetValue(data.text)end end,
},
}

function SaveManager.SetIgnoreIndexes(self,list)
for _,key in list do self.Ignore[key]=true end
end

function SaveManager.BuildFolderTree(self)
for _,folder in{self.Folder,self.Folder.."/settings",self.Folder.."/themes"}do
local ok,err=Storage.MakeFolders(folder)
if not ok then return false,tostring(err)end
end
return true
end

function SaveManager.SetFolder(self,folder)
self.Folder=folder
local ok,err=self:BuildFolderTree()
if not ok and self.Library then self.Library:Notify("Storage unavailable: "..err)end
return ok,err
end

function SaveManager.SetLibrary(self,library)
self.Library=library
library.SaveManager=self
end

function SaveManager.Capture(self)
local data={schemaVersion=1,objects={}}
for _,collection in{Toggles,Options}do
for idx,object in collection do
local parser=self.Parser[object.Type]
if parser and not self.Ignore[idx]then
table.insert(data.objects,parser.Save(idx,object))
end
end
end
table.sort(data.objects,function(a,b)return a.idx<b.idx end)
local function copy(value)
if type(value)~="table"then return value end
local result={}
for key,item in value do result[key]=copy(item)end
return result
end
return copy(data)
end

function SaveManager.Flush(self)
if not self.Dirty or not self.ActiveProfile then return true end
return self:Save(self.ActiveProfile)
end

function SaveManager.Save(self,name)
name=name or self.ActiveProfile
if not Storage.ValidName(name)then return false,"invalid or missing profile name"end
if self.Loading then return false,"profile load in progress"end
if self.Previewing then return false,"apply or cancel visual preview before saving"end
if self.ActiveProfile and name~=self.ActiveProfile then
local flushed,flushError=self:Flush()
if not flushed then return false,"previous profile save failed: "..tostring(flushError)end
end
local ok,encoded=pcall(function()return HttpService:JSONEncode(self:Capture())end)
if not ok then return false,"encode failed: "..tostring(encoded)end
local saved,err=Storage.Write(self.Folder.."/settings/"..name..".json",encoded)
if saved then
if self.ActiveProfile~=name then self:InvalidateQueue()end
self.ActiveProfile=name
self.Dirty=false
end
return saved,err
end

function SaveManager.Validate(self,data)
if type(data)~="table"or type(data.objects)~="table"then return false,"objects must be an array"end
if data.schemaVersion~=nil and data.schemaVersion~=1 then return false,"unsupported profile version"end
local count=0
for key in data.objects do
if type(key)~="number"or key<1 or key%1~=0 then return false,"objects must be an array"end
count=count+1
end
if count~=#data.objects or count>1000 then return false,"invalid profile array size"end
local entries,seen={},{}
for _,entry in data.objects do local __DARKLUA_CONTINUE_105=false repeat
if type(entry)~="table"or type(entry.idx)~="string"or type(entry.type)~="string"then
return false,"invalid profile entry"
end
if seen[entry.idx]then return false,"duplicate setting: "..entry.idx end
seen[entry.idx]=true
local object=entry.type=="Toggle"and Toggles[entry.idx]or Options[entry.idx]
if not object or self.Ignore[entry.idx]then __DARKLUA_CONTINUE_105=true break end
if object.Type~=entry.type or not self.Parser[entry.type]then return false,"setting type mismatch: "..entry.idx end
local value=table.clone(entry)
if entry.type=="Toggle"then
if type(entry.value)~="boolean"then return false,"invalid toggle: "..entry.idx end
elseif entry.type=="Slider"then
value.value=tonumber(entry.value)
if not Storage.Finite(value.value)then return false,"invalid slider: "..entry.idx end
elseif entry.type=="ColorPicker"then
if type(entry.value)~="string"or not entry.value:match"^%x%x%x%x%x%x$"then return false,"invalid color: "..entry.idx end
value.transparency=entry.transparency or 0
if not Storage.Finite(value.transparency)or value.transparency<0 or value.transparency>1 then return false,"invalid transparency"end
elseif entry.type=="KeyPicker"then
if type(entry.key)~="string"or not({Always=true,Toggle=true,Hold=true})[entry.mode]then return false,"invalid binding: "..entry.idx end
if entry.key~="-"and entry.key~=""and entry.key~="MB1"and entry.key~="MB2"then
local known,key=pcall(function()return Enum.KeyCode[entry.key]end)
if not known or not key then return false,"unknown key: "..entry.key end
end
value.key=entry.key==""and"-"or entry.key
elseif entry.type=="Input"then
if type(entry.text)~="string"or#entry.text>4096 then return false,"invalid input: "..entry.idx end
elseif entry.type=="Dropdown"then
if object.Multi then
if type(entry.value)~="table"then return false,"invalid multi-selection: "..entry.idx end
for key,enabled in entry.value do
if type(key)~="string"or type(enabled)~="boolean"then return false,"invalid selection entry"end
end
elseif entry.value~=nil and type(entry.value)~="string"then return false,"invalid selection: "..entry.idx end
end
table.insert(entries,value)__DARKLUA_CONTINUE_105=true until true if not __DARKLUA_CONTINUE_105 then break end
end
local priority={AllowUnsafeFeatures=0,ChantSpamGender=1,ChantSpamNation=2,ChantSpamSet=3,BypassRangeCheck=4}
table.sort(entries,function(a,b)
local pa,
pb=priority[a.idx]or(a.type=="Toggle"and 20 or 10),priority[b.idx]or(b.type=="Toggle"and 20 or 10)
return pa==pb and a.idx<b.idx or pa<pb
end)
return true,entries
end

function SaveManager.ReadDocument(self,name,backup)
if not Storage.ValidName(name)then return false,"invalid profile name"end
local ok,data=Storage.Read(self.Folder.."/settings/"..name..".json"..(backup and".bak"or""))
if not ok then return false,"read failed: "..tostring(data)end
if#data>1048576 then return false,"profile exceeds 1 MiB"end
ok,data=pcall(function()return HttpService:JSONDecode(data)end)
if not ok then return false,"decode failed: "..tostring(data)end
local valid,entries=self:Validate(data)
if not valid then return false,entries end
return true,data
end

function SaveManager.Preview(self,data)
local valid,entries=self:Validate(data)
if not valid then return false,entries end
local before,report={},{Changed={},Skipped={},Constrained={}}
for _,entry in self:Capture().objects do before[entry.idx]=entry end
for _,entry in data.objects do
if not before[entry.idx]then table.insert(report.Skipped,entry.idx)end
end
for _,entry in entries do
local function equal(a,b)
if type(a)~=type(b)then return false end
if type(a)~="table"then return a==b end
for key,value in a do if not equal(value,b[key])then return false end end
for key in b do if a[key]==nil then return false end end
return true
end
if not equal(before[entry.idx],entry)then
table.insert(report.Changed,entry.idx)
end
local option=Options[entry.idx]
if entry.type=="Slider"and option and(entry.value<option.Min or entry.value>option.Max)then
table.insert(report.Constrained,entry.idx)
end
end
return true,report
end

function SaveManager.ApplyDocument(self,data,name)
if self.Loading then return false,"profile load already in progress"end
if self.Previewing then return false,"apply or cancel visual preview before loading"end
local valid,entries=self:Validate(data)
if not valid then return false,entries end
local flushed,flushError=self:Flush()
if not flushed then return false,"previous profile save failed: "..tostring(flushError)end
local captured,snapshot=pcall(function()return self:Capture()end)
if not captured then return false,"snapshot failed: "..tostring(snapshot)end
self:InvalidateQueue()
if self.Library then self.Library.SaveQueued=false end
self.Loading=true
local report,
priorThrow={Applied={},Restored={},FailedRestorations={},FailedSetting=nil},self.Library and self.Library.ThrowCallbackErrors
if self.Library then self.Library.ThrowCallbackErrors=true end
local success,err=pcall(function()
for _,entry in entries do
report.FailedSetting=entry.idx
self.Parser[entry.type].Load(entry.idx,entry)
table.insert(report.Applied,entry.idx)
end
report.FailedSetting=nil
end)
if not success then
local rollbackValid,original=self:Validate(snapshot)
if not rollbackValid then
table.insert(report.FailedRestorations,{Id="snapshot",Error=tostring(original)})
else
for _,entry in original do
local restored,restoreError=pcall(self.Parser[entry.type].Load,entry.idx,entry)
if restored then table.insert(report.Restored,entry.idx)
else table.insert(report.FailedRestorations,{Id=entry.idx,Error=tostring(restoreError)})end
end
end
end
self.Loading=false
if self.Library then self.Library.ThrowCallbackErrors=priorThrow end
self.LastReport=report
if not success then
return false,"apply failed: "..tostring(err).."; restoration failures: "..#report.FailedRestorations,report
end
if name then self.ActiveProfile=name end
self.Dirty=false
return true,nil,report
end

function SaveManager.Load(self,name)
local ok,data=self:ReadDocument(name)
if not ok then return false,data end
return self:ApplyDocument(data,name)
end

function SaveManager.RecoverBackup(self,name)
local ok,data=self:ReadDocument(name,true)
if not ok then return false,data end

local recovered=name:sub(1,52).."-recovered"
local checked,exists=Storage.Exists(self.Folder.."/settings/"..recovered..".json")
if not checked then return false,exists end
if exists then return false,"recovery profile already exists"end
local encoded,payload=pcall(function()return HttpService:JSONEncode(data)end)
if not encoded then return false,payload end
local saved,err=Storage.Write(self.Folder.."/settings/"..recovered..".json",payload)
if not saved then return false,err end
return true,recovered
end

function SaveManager.Export(self,name)
local ok,data=self:ReadDocument(name)
if not ok then return false,data end
return pcall(function()return HttpService:JSONEncode(data)end)
end

function SaveManager.Import(self,name,payload)
if not Storage.ValidName(name)or type(payload)~="string"or#payload>1048576 then return false,"invalid import"end
local checked,exists=Storage.Exists(self.Folder.."/settings/"..name..".json")
if not checked then return false,exists end
if exists then return false,"profile already exists"end
local decoded,data=pcall(function()return HttpService:JSONDecode(payload)end)
if not decoded then return false,data end
local valid,err=self:Validate(data)
if not valid then return false,err end
data.schemaVersion=1
local encoded,migrated=pcall(function()return HttpService:JSONEncode(data)end)
if not encoded then return false,migrated end
return Storage.Write(self.Folder.."/settings/"..name..".json",migrated)
end

function SaveManager.Duplicate(self,source,destination)
local ok,payload=self:Export(source)
if not ok then return false,payload end
return self:Import(destination,payload)
end

function SaveManager.InvalidateQueue(self)
self.Generation=self.Generation+1
if self.Library then
self.Library.SaveToken=(self.Library.SaveToken or 0)+1
self.Library.SaveQueued=false
end
end

function SaveManager.ReadAutoload(self)
local path=self.Folder.."/settings/autoload.txt"
local checked,exists=Storage.Exists(path)
if not checked then return false,exists end
if not exists then return true,nil end
return Storage.Read(path)
end

function SaveManager.Rename(self,source,destination)
if self.Previewing then return false,"apply or cancel visual preview first"end
if not Storage.ValidName(source)or not Storage.ValidName(destination)then return false,"invalid name"end
local flushed,err=self:Flush()
if not flushed then return false,err end
local autoloadOk,autoload=self:ReadAutoload()
if not autoloadOk then return false,"autoload read failed: "..tostring(autoload)end
local copied,copyError=self:Duplicate(source,destination)
if not copied then return false,copyError end
if autoloadOk and autoload==source then
local updated,updateError=Storage.Write(self.Folder.."/settings/autoload.txt",destination)
if not updated then return false,"copy saved; autoload update failed: "..tostring(updateError)end
end
local deleted,deleteError=pcall(delfile,self.Folder.."/settings/"..source..".json")
if not deleted then return false,"copy saved; old profile deletion failed: "..tostring(deleteError)end
if self.ActiveProfile==source then self.ActiveProfile=destination self:InvalidateQueue()end
return true
end

function SaveManager.Delete(self,name)
if self.Previewing then return false,"apply or cancel visual preview first"end
if not Storage.ValidName(name)then return false,"invalid name"end
local flushed,flushError=self:Flush()
if not flushed then return false,flushError end
local autoloadOk,autoload=self:ReadAutoload()
if not autoloadOk then return false,"autoload read failed: "..tostring(autoload)end
if autoloadOk and autoload==name then
local removed,err=pcall(delfile,self.Folder.."/settings/autoload.txt")
if not removed then return false,err end
end
local ok,err=pcall(delfile,self.Folder.."/settings/"..name..".json")
if ok and self.ActiveProfile==name then self.ActiveProfile=nil self:InvalidateQueue()end
return ok,err
end

function SaveManager.IgnoreThemeSettings(self)
self:SetIgnoreIndexes{"BackgroundColor","MainColor","AccentColor","OutlineColor","FontColor","RiskColor","DisabledColor","ThemeManager_ThemeList","ThemeManager_CustomThemeList","ThemeManager_CustomThemeName"}
end

function SaveManager.RefreshConfigList(self)
local ok,result=Storage.List(self.Folder.."/settings",".json")
if not ok then
if self.Library then self.Library:Notify("Profile list failed: "..result)end
return{}
end
return result
end

function SaveManager.LoadAutoloadConfig(self)
local ok,name=Storage.Read(self.Folder.."/settings/autoload.txt")
if not ok or name==""then return end
local success,err=self:Load(name)
self.Library:Notify(success and("Auto loaded profile "..name)or("Autoload failed: "..err))
end

function SaveManager.BuildConfigSection(self,tab)
assert(self.Library,"Must set SaveManager.Library")
local section=tab:AddRightGroupbox"Configuration"
section:AddInput("SaveManager_ConfigName",{Text="Config name"})
section:AddDropdown("SaveManager_ConfigList",{Text="Config list",Values=self:RefreshConfigList(),AllowNull=true})
section:AddDivider()local report=function(
success, err, message)
self.Library:Notify(success and message or tostring(err))
if success then Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())end end

section:AddButton("Create config",function()
local ok,err=self:Save(Options.SaveManager_ConfigName.Value)
report(ok,err,"Profile created")
end):AddButton("Load config",function()
local ok,err=self:Load(Options.SaveManager_ConfigList.Value)
report(ok,err,"Profile loaded")
end)
section:AddButton("Overwrite config",function()
local ok,err=self:Save(Options.SaveManager_ConfigList.Value)
report(ok,err,"Profile saved")
end)
section:AddButton("Refresh list",function()Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())end)
section:AddButton("Set as autoload",function()
local name=Options.SaveManager_ConfigList.Value
if not Storage.ValidName(name)then return self.Library:Notify"Select a valid profile"end
local ok,err=Storage.Write(self.Folder.."/settings/autoload.txt",name)
if not ok then return self.Library:Notify(tostring(err))end
self.AutoloadLabel:SetText("Current autoload config: "..name)
end)
section:AddButton("Remove autoload",function()
local ok,err=pcall(function()
local path=self.Folder.."/settings/autoload.txt"
if isfile(path)then delfile(path)end
end)
if not ok then return self.Library:Notify(tostring(err))end
self.AutoloadLabel:SetText"Current autoload config: none"
end)
self.AutoloadLabel=section:AddLabel("Current autoload config: none",true)
local ok,name=Storage.Read(self.Folder.."/settings/autoload.txt")
if ok and Storage.ValidName(name)then self.AutoloadLabel:SetText("Current autoload config: "..name)end
self:SetIgnoreIndexes{"SaveManager_ConfigList","SaveManager_ConfigName"}
end

SaveManager:BuildFolderTree()
return SaveManager end function init.o()local v=init.cache.o if not v then v={c=__modImpl()}init.cache.o=v end return v.c end end do local __modImpl=function()

local Services={}

for _,Service in{"Players","RunService","UserInputService","CoreGui","Debris","ReplicatedStorage","Lighting","HttpService","PathfindingService"}do
Services[Service]=cloneref(game:GetService(Service))
end

return Services end function init.p()local v=init.cache.p if not v then v={c=__modImpl()}init.cache.p=v end return v.c end end do local __modImpl=function()

local Modules,







typeof,
getfenv,
string_find={LoadedModules=getloadedmodules(),Cache={},GarbageCollection=filtergc("function",{IgnoreExecutor=true,}),},typeof,getfenv,string.find

function Modules.GetModule(self,Name,Required)
local cached=self.Cache[Name]

if cached and cached.Required==Required then
return cached.Value
end

for i=1,#self.LoadedModules do
local Module=self.LoadedModules[i]

if Module.Name==Name then
local Value=Required and require(Module)or Module

self.Cache[Name]={
Value=Value,
Required=Required,
Module=Module,
}

return Value
end
end

for Index=1,#Modules.GarbageCollection do local __DARKLUA_CONTINUE_116=false repeat
local Value=Modules.GarbageCollection[Index]

if not Value or typeof(Value)~="function"then __DARKLUA_CONTINUE_116=true
break
end

local source=debug.info(Value,"s")
if not source or not string_find(source,Name,1,true)then __DARKLUA_CONTINUE_116=true
break
end

local env=getfenv(Value)
if typeof(env)~="table"then __DARKLUA_CONTINUE_116=true
break
end

if env.script then
local Module=Required and require(env.script)or env.script

self.Cache[Name]={
Value=Module,
Required=Required,
Module=env.script,
}

return Module
end __DARKLUA_CONTINUE_116=true until true if not __DARKLUA_CONTINUE_116 then break end
end

return nil
end

return Modules end function init.q()local v=init.cache.q if not v then v={c=__modImpl()}init.cache.q=v end return v.c end end do local __modImpl=function()

local Variables,




GarbageCollection={Cache={},Captured={},},getgc(true)

Variables.VariablesIndex=(LPH_JIT_MAX(function()
for i=1,#GarbageCollection do local __DARKLUA_CONTINUE_117=false repeat
local Value=GarbageCollection[i]

if typeof(Value)~="function"then __DARKLUA_CONTINUE_117=true
break
end

local info=debug.getinfo(Value)

if not info or not string.match(info.source,"ReplicatedStorage.Variables")then __DARKLUA_CONTINUE_117=true
break
end

if info.name=="index"then __DARKLUA_CONTINUE_117=true
break
end

return Value until true if not __DARKLUA_CONTINUE_117 then break end
end

return nil
end))()

assert(type(Variables.VariablesIndex)=="function","Variables dependency unavailable")
local InitialVariables=debug.getupvalue(Variables.VariablesIndex,1)
assert(type(InitialVariables)=="table","Variables dependency has an incompatible shape")
for Key,Value in InitialVariables do
Variables.Captured[Key]=true
Variables.Cache[Key]=Value
end

Variables.SetVariable=LPH_JIT_MAX(function(Key,Value,RestoreOriginal)
local CurrentVariables=debug.getupvalue(Variables.VariablesIndex,1)

if not RestoreOriginal then
if not Variables.Captured[Key]then
Variables.Captured[Key]=true
Variables.Cache[Key]=rawget(CurrentVariables,Key)
end

pcall(rawset,CurrentVariables,Key,Value)
else
if Variables.Captured[Key]then
pcall(rawset,CurrentVariables,Key,Variables.Cache[Key])
end
end
end)init.b()

.Add(function()
local values=debug.getupvalue(Variables.VariablesIndex,1)
for key in Variables.Captured do rawset(values,key,Variables.Cache[key])end
end)
return Variables end function init.r()local v=init.cache.r if not v then v={c=__modImpl()}init.cache.r=v end return v.c end end do local __modImpl=function()
local Utils,
Runtime={},init.b()
function Utils.Dispose(value)Runtime.Release(value,true)end

Utils.Draw=LPH_JIT_MAX(function(Class,Properties)
local success,instance=pcall(Drawing.new,Class)

if not success then
return false
end

Runtime.Own(instance,function(value)value:Remove()end)
if Properties then
for key,value in next,Properties do
local succ,err=pcall(function()
(instance)[key]=value
end)

if not succ then
warn(err)
Runtime.Release(instance,true)
return false
end
end
end

return instance
end)

Utils.Create=LPH_JIT_MAX(function(Class,Properties)
local success,instance=pcall(Instance.new,Class)

if not success then
return false
end

Runtime.Own(instance)
if Properties then
for key,value in next,Properties do
local succ,err=pcall(function()
(instance)[key]=value
end)

if not succ then
warn(err)
Runtime.Release(instance,true)
return false
end
end
end

return instance
end)

Utils.IsWithinRadius=LPH_JIT_MAX(function(Point,TargetPoint,Radius)
return(TargetPoint-Point).Magnitude<=Radius
end)

local Params=RaycastParams.new()
Params.IgnoreWater=true
Params.FilterType=Enum.RaycastFilterType.Exclude
Params.FilterDescendantsInstances={
game:GetService"Players".LocalPlayer.Character,
workspace.CurrentCamera,
}

Utils.IsVisible=LPH_JIT_MAX(function(TargetPart)
if not TargetPart or not TargetPart:IsA"BasePart"then
return false
end

local Camera=workspace.CurrentCamera
if not Camera or not TargetPart.Parent then return false end
local exclusions,
character={Camera},game:GetService"Players".LocalPlayer.Character
if character then table.insert(exclusions,character)end
Params.FilterDescendantsInstances=exclusions
local Origin=Camera.CFrame.Position
local Direction=TargetPart.Position-Origin

local Result=workspace:Raycast(Origin,Direction,Params)

if not Result then
return true
end

return Result.Instance:IsDescendantOf(TargetPart.Parent)
end)

Utils.GetFunction=LPH_JIT_MAX(function(Name,Hash,Source)
if not filtergc then
return nil
end

local filterOptions={IgnoreExecutor=true}

if Name then
filterOptions.name=Name
end

if Hash then
filterOptions.hash=Hash
end

local funcs=filtergc("function",filterOptions)

for i=1,#funcs do
local func=funcs[i]

local yep,match=pcall(function()
local name,
source=not Name or debug.info(func,"n")==Name,not Source or string.find(debug.info(func,"s"),Source,1,true)~=nil

return name and source
end)

if yep and match then
return func
end
end

return nil
end)

Utils.SecureCall=LPH_NO_VIRTUALIZE(function(func,script,...)
return func(...)
end)

Utils.SecureHook=function(target,replacement)
assert(type(target)=="function"and type(replacement)=="function","hook dependency unavailable")
local original=hookfunction(target,replacement)init.b()
.Add(function()hookfunction(target,original)end)
return original
end

return Utils end function init.s()local v=init.cache.s if not v then v={c=__modImpl()}init.cache.s=v end return v.c end end do local __modImpl=function()

return init.s()end function init.t()local v=init.cache.t if not v then v={c=__modImpl()}init.cache.t=v end return v.c end end do local __modImpl=function()






















return{
FireServer='0e7b12fb58b6088d27871ccc87808c2ebd158fc126928bcde522fcf126d7a8e5fb490aea582c9f84bb73ae7b2f5eff11',
shakeCamera='903e4863e214219ab4546f04d2313a01b1506e1732d2e6bd869fa797ea6e03d8b840150f03500bd8c3a98bfb89020c51',
GetDamage='2e9573b7cc5e39c32a53372647385001c0dce0eff9979f9e868812d0eef1e3b6285ba2cbbd64b9534fa92281155325d0',
shakeFiredShot='0f268340ea6474d2d4e2aad04eb5032a15d658f4bb67d203257145aca8cc9c175f7541c97b1cfa44a94a6e0711732e13',
getMisfired='a6a6dd1fa66d01a18d3d5315a7d84699d4d584752b15a0c0ca7c7bd89b3c69989b15c0d0eeb9a0edbdce06e82ade2c4c',
bulletPass='43992177b294755ef4aab776e5e51994df52fddea21bd8100c860ab4d6e87ae95f4db6d50b4c54fa1f5ccda018a973cc',
cannonPassMoraleShock='150e30abb543c96b58a47caf6776319d652d845819f1ab73d2e9b7c7cdaa16dc40889c447c93a4e8fa227c5f41a8ea0e',
RenderStepped='1837bd7b5a9172741864d480e5280795c3ab48a3bee87a2b5d5e3152df7beb971102171a047409ac2940b96d30d4976d',
Fire='e3699e5bc5d60be8da3a3e1c05dc674a980ec15bba784c784c1fbbe0b9d55e1cfb60d353ba1ebee22d439166cb21d9cd',
RunTouchTest='e06bd04bfdf314a907b9d852e56a14c18dbcef2e22eb8a4de9c8e324129f2c4f56c16232592a1bcbd68297d1a971dad5',
dealShot='bda8d0b6f8992dd7e836345278262fe8ace9ad048143a4a6986f87a26e0303ddd642ea96c1e2e93b232f96d28b3e6d23',
simulateFirearmProjectile='12aacb89509b462a43fb1e0e3c3de01ef4c9885aa0c8a088f3996be5faa738207396a888cfd16616facbcce0fa888b1b',
checkMelee='fd03119bdcab7ad84d7abf1d04ae6b244ba1bcb3de40b3de65c7ccb8e9089f8ebca4bd843eff29ed5e9c9837b59f325f',
dealMelee='1a1553e0392669b5f386a2f859870eb328ee32602a40df89cbdc88941645e6d919b04b62fe8d833b8f2b5ce94199004a',
PromptTriggered='f73776462042f427e524eb454224a931c82497f4f4b16c119dc219693b0ae86bf0d8c86e68ed402500e05e143f100327',
PromptBegan='f71e16dc926d9ccf4e2ebac16d4d61e1e3de0140b43015667d4a3b2fe9d40d0db662eaf5e5bdcc55a8a3a5bd6e42323d',
startScatter='4c9a0798f03bf179aa122643bc2d222caaa91990744242f23618dd9028af96a1c6ed808ae66f4d4fa14d0bda530f2dd7',
}end function init.u()local v=init.cache.u if not v then v={c=__modImpl()}init.cache.u=v end return v.c end end do local __modImpl=function()
return{
Services=init.p(),
Modules=init.q(),
Variables=init.r(),
Utils=init.t(),
Hashes=init.u()
}end function init.v()local v=init.cache.v if not v then v={c=__modImpl()}init.cache.v=v end return v.c end end do local __modImpl=function()

local Networking,




Core={Debounces={},Blacklist={"SelfReport"},},init.v()
local Utils,
Modules=Core.Utils,Core.Modules

local Bucket,
NetworkClient,
NetworkEvents=Modules:GetModule("Bucket",true),Modules:GetModule("NetworkClient",true),Modules:GetModule("NetworkEvents",true)

Utils.SecureHook(Bucket.calculateBucketWeight,function(...)
return 0
end)

local FireServer=Utils.GetFunction("FireServer",Core.Hashes.FireServer,"NetworkClient")
or LPH_JIT_MAX(function()
local upvalue=debug.getupvalue(NetworkClient.getEvent,5)

if typeof(upvalue)~="table"then
return nil
end

for _,v in upvalue do local __DARKLUA_CONTINUE_123=false repeat
if typeof(v)~="function"then __DARKLUA_CONTINUE_123=true
break
end

if debug.info(v,"n")~="FireServer"then __DARKLUA_CONTINUE_123=true
break
end

return v until true if not __DARKLUA_CONTINUE_123 then break end
end

return nil
end)()

if not FireServer then
game:GetService"Players".LocalPlayer:Kick"safety kick 0x3 - failed to get FireServer function"
end

local OldFireServer
OldFireServer=Utils.SecureHook(FireServer,function(event,...)
if table.find(Networking.Blacklist,event.eventName)then
if not LPH_OBFUSCATED then
print("Prevented event from firing: -> ",event.eventName,"\nArguments: ->",unpack{...},"\n",debug.traceback())
end

return
end

return OldFireServer(event,...)
end)

function Networking.AddBlacklist(self,eventName)
if typeof(eventName)~="string"then
warn"Networking.AddBlacklist: eventName must be a string"
return
end

if table.find(Networking.Blacklist,eventName)then

return
end

table.insert(Networking.Blacklist,eventName)
end

function Networking.RemoveBlacklist(self,eventName)
if typeof(eventName)~="string"then
warn"Networking.RemoveBlacklist: eventName must be a string"
return
end

local index=table.find(Networking.Blacklist,eventName)
if not index then

return
end

table.remove(Networking.Blacklist,index)
end

function Networking.FireEvent(self,eventName,debounce,...)
local arguments={...}

if typeof(eventName)~="string"then
warn("Networking.FireEvent: Parameter #1 expects a string, but a:",typeof(eventName),"was passed")
return
end

local info=NetworkEvents.getEventInfo(eventName)
if not info then
warn("Networking.FireEvent: No event of the name:",eventName,"was found")
return
end

local event=NetworkClient.getEvent(eventName)
if not event then
warn("Networking.FireEvent: Failed to fetch event for:",eventName)
return
end

if debounce then
if typeof(debounce)~="number"then
warn("Networking.FireEvent: Parameter #2 expects a number, but a:",typeof(debounce),"was passed")
return
end

if not Networking.Debounces[eventName]then
Networking.Debounces[eventName]={
Cooldown=debounce,
LastUpdate=0,
}
end

local DebounceData=Networking.Debounces[eventName]

if os.clock()-DebounceData.LastUpdate>=DebounceData.Cooldown then
DebounceData.LastUpdate=os.clock()
event:FireServer(unpack(arguments))
end
else
event:FireServer(unpack(arguments))
end
end

return Networking end function init.w()local v=init.cache.w if not v then v={c=__modImpl()}init.cache.w=v end return v.c end end do local __modImpl=function()

return init.w()end function init.x()local v=init.cache.x if not v then v={c=__modImpl()}init.cache.x=v end return v.c end end do local __modImpl=function()local HitboxExtender,










Core={Config={Enabled=false,SizeIncrease=2,Transparency=0,Material=Enum.Material.ForceField,Color=Color3.fromRGB(255,255,255),},},init.v()
local Utils,

Modules,
Services=Core.Utils,Core.Modules,Core.Services

local Players=Services.Players
local LocalPlayer,

WeaponsDamageClient,
CombatTouchTestClient=Players.LocalPlayer,Modules:GetModule("WeaponsDamageClient",true),Modules:GetModule("CombatTouchTestClient",true)

local RunTouchTest=
Utils.GetFunction("RunTouchTest",Core.Hashes.RunTouchTest,"CombatTouchTestClient")
or debug.getupvalue(CombatTouchTestClient.start,3)

Utils.SecureHook(RunTouchTest,function()
return false
end)

local OldDealShot
OldDealShot=Utils.SecureHook(WeaponsDamageClient.dealShot,function(Player,Humanoid,c,d,e)
d=d:Lerp(c.Position,0.999)
return OldDealShot(Player,Humanoid,c,d,e)
end)

local Originals=setmetatable({},{__mode="k"})local Capture, Disable=function(
part)
if Originals[part]then return end
Originals[part]={Transparency=part.Transparency,Size=part.Size,Color=part.Color,Material=part.Material}end, function(


part)
local properties=Originals[part]
if not properties then return end
for name,value in properties do
pcall(function()part[name]=value end)
end
Originals[part]=nil end


HitboxExtender.OnDisable=LPH_JIT_MAX(function()
for part in Originals do Disable(part)end
end)

HitboxExtender.Update=LPH_JIT_MAX(function()
if not HitboxExtender.Config.Enabled then
return
end

if not(getgenv().Options and getgenv().Options.HitboxExtenderBind and getgenv().Options.HitboxExtenderBind:GetState())then
HitboxExtender.OnDisable()
return
end

local Players=Players:GetPlayers()

for i=1,#Players do local __DARKLUA_CONTINUE_126=false repeat
local Player=Players[i]

if Player==LocalPlayer then __DARKLUA_CONTINUE_126=true
break
end

if not Player.Character then __DARKLUA_CONTINUE_126=true
break
end

local Character=Player.Character
local HumanoidRootPart=Character and Character:FindFirstChild"HumanoidRootPart"

if not HumanoidRootPart then __DARKLUA_CONTINUE_126=true
break
end

if Player.Team==LocalPlayer.Team then
Disable(HumanoidRootPart)__DARKLUA_CONTINUE_126=true
break
end

local Humanoid=Character:FindFirstChild"Humanoid"

if not Humanoid then
Disable(HumanoidRootPart)__DARKLUA_CONTINUE_126=true
break
end

if Humanoid.Health<=0 then
Disable(HumanoidRootPart)__DARKLUA_CONTINUE_126=true
break
end

if Humanoid.MaxHealth>100 then
Disable(HumanoidRootPart)__DARKLUA_CONTINUE_126=true
break
end

Capture(HumanoidRootPart)
HumanoidRootPart.Color=HitboxExtender.Config.Color
HumanoidRootPart.Material=HitboxExtender.Config.Material
HumanoidRootPart.Transparency=getgenv().Options and getgenv().Options.HitboxExtenderColor and getgenv().Options.HitboxExtenderColor.Transparency or HitboxExtender.Config.Transparency
HumanoidRootPart.Size=Vector3.new(2,2,2)*HitboxExtender.Config.SizeIncrease __DARKLUA_CONTINUE_126=true until true if not __DARKLUA_CONTINUE_126 then break end
end
end)

return HitboxExtender end function init.y()local v=init.cache.y if not v then v={c=__modImpl()}init.cache.y=v end return v.c end end do local __modImpl=function()
local Runtime,
Tracers=init.b(),{
Config={Enabled=false,Duration=5,Color=Color3.fromRGB(255,255,255),MaxSegments=128},
Segments={},
}local Remove=function(

index)
local segment=table.remove(Tracers.Segments,index)
if segment then pcall(function()segment.Line:Remove()end)end end


function Tracers.Clear()
for index=#Tracers.Segments,1,-1 do Remove(index)end
end

function Tracers.Add(startPosition,endPosition)
if not Runtime.Alive or not Tracers.Config.Enabled then return end
local maximum=tonumber(Tracers.Config.MaxSegments)or 128
if maximum~=maximum then maximum=128 end
maximum=math.clamp(math.floor(maximum),1,512)
while#Tracers.Segments>=maximum do Remove(1)end
local ok,line=pcall(Drawing.new,"Line")
if not ok then Runtime.Record("tracer drawing",line)return end
local initialized,err=pcall(function()
line.Visible=false
line.Color=Tracers.Config.Color
local duration=tonumber(Tracers.Config.Duration)or 5
if duration~=duration then duration=5 end
duration=math.clamp(duration,0.01,60)
table.insert(Tracers.Segments,{Line=line,From=startPosition,To=endPosition,Expires=os.clock()+duration})
end)
if not initialized then
pcall(function()line:Remove()end)
Runtime.Record("tracer initialization",err)
end
end

function Tracers.Update()
if not Tracers.Config.Enabled then Tracers.Clear()return end
local maximum=tonumber(Tracers.Config.MaxSegments)or 128
if maximum~=maximum then maximum=128 end
maximum=math.clamp(math.floor(maximum),1,512)
while#Tracers.Segments>maximum do Remove(1)end
local camera,
now=workspace.CurrentCamera,os.clock()
for index=#Tracers.Segments,1,-1 do local __DARKLUA_CONTINUE_130=false repeat
local segment=Tracers.Segments[index]
if segment.Expires<=now then Remove(index)__DARKLUA_CONTINUE_130=true break end
local line=segment.Line
if not camera then line.Visible=false __DARKLUA_CONTINUE_130=true break end
local a,aVisible=camera:WorldToViewportPoint(segment.From)
local b,bVisible=camera:WorldToViewportPoint(segment.To)
line.Visible=aVisible and bVisible
if line.Visible then
line.From=Vector2.new(a.X,a.Y)
line.To=Vector2.new(b.X,b.Y)
line.Transparency=math.clamp((segment.Expires-now)/0.15,0,1)
end __DARKLUA_CONTINUE_130=true until true if not __DARKLUA_CONTINUE_130 then break end
end
end

Runtime.Add(Tracers.Clear)
return Tracers end function init.z()local v=init.cache.z if not v then v={c=__modImpl()}init.cache.z=v end return v.c end end do local __modImpl=function()

local Core,
BulletTracers=init.v(),init.z()

local Utils,
Modules,
Services=Core.Utils,Core.Modules,Core.Services

local Players,
UserInputService,

Camera=Services.Players,Services.UserInputService,workspace.CurrentCamera
local LocalPlayer,

SilentAim=Players.LocalPlayer,{
Config={
Enabled=false,
Toggled=false,

Smoothing=0.15,
Hitchance=100,
Distance=500,

VisibleCheck=false,
FlagBearerPriority=false,

Hitpart="Head",
},

FOVConfig={
Enabled=false,
Outline=false,
Visible=false,
Filled=false,

Radius=100,
Thickness=1,
NumSides=20,
Transparency=0,

Color=Color3.fromRGB(44,124,254),
},

FOVFillConfig={
Transparency=0.7,
Color=Color3.fromRGB(44,124,254),
},

LineConfig={
Enabled=false,
Outline=false,

Thickness=1,
Transparency=1,
Color=Color3.new(1,1,1),
},

Line=Utils.Draw("Line",{
ZIndex=11,
Visible=false,
}),

LineOutline=Utils.Draw("Line",{
ZIndex=10,
Visible=false,
Color=Color3.new(0,0,0),
}),

FOVCircle=Utils.Draw("Circle",{
ZIndex=11,
Visible=false,
}),

FOVCircleOutline=Utils.Draw("Circle",{
ZIndex=10,
Visible=false,
Color=Color3.new(0,0,0),
}),

FOVCircleFill=Utils.Draw("Circle",{
ZIndex=9,
Visible=false,
Filled=true,
}),

Target=nil,
TargetPart=nil,
}

SilentAim.GetClosest=LPH_JIT_MAX(function()
if not SilentAim.Config.Enabled then
return nil,nil
end

if not(getgenv().Options and getgenv().Options.SilentAimBind and getgenv().Options.SilentAimBind:GetState())then
return nil,nil
end

local Distance,FlagBearer,
FlagBearerDistance,

Players,Closest,Part,FlagBearerClosest,FlagBearerPart=math.huge,false,math.huge,(Players:GetPlayers())

for i=1,#Players do local __DARKLUA_CONTINUE_131=false repeat
local Player=Players[i]

if Player==LocalPlayer then __DARKLUA_CONTINUE_131=true
break
end

if Player.Team==LocalPlayer.Team then __DARKLUA_CONTINUE_131=true
break
end

local Character=Player.Character

if not Character then __DARKLUA_CONTINUE_131=true
break
end

local MaxDistance,CharacterDistance=
SilentAim.Config.Distance^2,Camera.CFrame.Position-Player.Character:GetPivot().Position
if CharacterDistance:Dot(CharacterDistance)>MaxDistance then __DARKLUA_CONTINUE_131=true
break
end

local Humanoid=Character:FindFirstChild"Humanoid"

if not Humanoid then __DARKLUA_CONTINUE_131=true
break
end

if Humanoid.Health<=0 then __DARKLUA_CONTINUE_131=true
break
end

if Humanoid.MaxHealth>100 then __DARKLUA_CONTINUE_131=true
break
end

local TargetPart=Character:FindFirstChild(SilentAim.Config.Hitpart)

if not TargetPart then __DARKLUA_CONTINUE_131=true
break
end

local ViewportPoint,OnScreen=Camera:WorldToViewportPoint(TargetPart.Position)

if not OnScreen then __DARKLUA_CONTINUE_131=true
break
end

local Vector=Vector2.new(ViewportPoint.X,ViewportPoint.Y)
local DistanceToMouse=(UserInputService:GetMouseLocation()-Vector).Magnitude

if DistanceToMouse>Distance then __DARKLUA_CONTINUE_131=true
break
end

if
not SilentAim.FOVConfig.Enabled
or Utils.IsWithinRadius(SilentAim.FOVCircle.Position,Vector,SilentAim.FOVConfig.Radius)
then
if not SilentAim.Config.VisibleCheck or Utils.IsVisible(TargetPart)then
if SilentAim.Config.FlagBearerPriority then
if Player:GetAttribute"FlagBearer"then
FlagBearer=true

if DistanceToMouse<FlagBearerDistance then
FlagBearerDistance=DistanceToMouse
FlagBearerPart=TargetPart
FlagBearerClosest=Player
end
else
if not FlagBearer and DistanceToMouse<Distance then
Distance=DistanceToMouse
Part=TargetPart
Closest=Player
end
end
else
if DistanceToMouse<Distance then
Distance=DistanceToMouse
Part=TargetPart
Closest=Player
end
end
end
end __DARKLUA_CONTINUE_131=true until true if not __DARKLUA_CONTINUE_131 then break end
end

if SilentAim.Config.FlagBearerPriority and FlagBearer then
return FlagBearerClosest,FlagBearerPart
end

return Closest,Part
end)

SilentAim.Update=LPH_JIT_MAX(function()
Camera=workspace.CurrentCamera
if not SilentAim.Config.Enabled or not Camera then
SilentAim.FOVCircle.Visible=false
SilentAim.FOVCircleOutline.Visible=false
SilentAim.FOVCircleFill.Visible=false

SilentAim.Line.Visible=false
SilentAim.LineOutline.Visible=false

SilentAim.Target,SilentAim.TargetPart=nil,nil

return
end

SilentAim.Target,SilentAim.TargetPart=SilentAim.GetClosest()
local SilentAimFOVLocation=UserInputService:GetMouseLocation()

if SilentAim.FOVConfig.Enabled then
local FOVCircle=SilentAim.FOVCircle
local LerpedLocation=FOVCircle.Position:Lerp(Vector2.new(SilentAimFOVLocation.X,SilentAimFOVLocation.Y),0.5)

FOVCircle.Radius=SilentAim.FOVConfig.Radius
FOVCircle.Thickness=SilentAim.FOVConfig.Thickness
FOVCircle.NumSides=SilentAim.FOVConfig.NumSides
FOVCircle.Color=SilentAim.FOVConfig.Color
FOVCircle.Transparency=getgenv().Options
and getgenv().Options.SilentAimFOVColor
and getgenv().Options.SilentAimFOVColor.Transparency
and math.clamp(1-getgenv().Options.SilentAimFOVColor.Transparency,0,1)
or SilentAim.FOVConfig.Transparency
FOVCircle.Visible=SilentAim.FOVConfig.Visible
FOVCircle.Position=LerpedLocation

if SilentAim.FOVConfig.Outline then
local FOVCircleOutline=SilentAim.FOVCircleOutline
FOVCircleOutline.Radius=SilentAim.FOVConfig.Radius
FOVCircleOutline.Thickness=SilentAim.FOVConfig.Thickness+2
FOVCircleOutline.NumSides=SilentAim.FOVConfig.NumSides
FOVCircleOutline.Visible=SilentAim.FOVConfig.Visible
FOVCircleOutline.Position=LerpedLocation
else
SilentAim.FOVCircleOutline.Visible=false
end

if SilentAim.FOVConfig.Filled then
local FOVCircleFill=SilentAim.FOVCircleFill
FOVCircleFill.Radius=SilentAim.FOVConfig.Radius
FOVCircleFill.Thickness=SilentAim.FOVConfig.Thickness
FOVCircleFill.NumSides=SilentAim.FOVConfig.NumSides
FOVCircleFill.Visible=SilentAim.FOVConfig.Visible

FOVCircleFill.Color=SilentAim.FOVFillConfig.Color
FOVCircleFill.Transparency=getgenv().Options
and getgenv().Options.SilentAimFOVFillColor
and getgenv().Options.SilentAimFOVFillColor.Transparency
and math.clamp(1-getgenv().Options.SilentAimFOVFillColor.Transparency,0,1)
or SilentAim.FOVFillConfig.Transparency
FOVCircleFill.Position=LerpedLocation
else
SilentAim.FOVCircleFill.Visible=false
end
else
SilentAim.FOVCircle.Visible=false
SilentAim.FOVCircleFill.Visible=false
SilentAim.FOVCircleOutline.Visible=false
end

if SilentAim.LineConfig.Enabled then
local Line,
LineOutline,

AimVector=SilentAim.Line,SilentAim.LineOutline,SilentAim.Target
and SilentAim.Target.Character
and SilentAim.Target.Character:FindFirstChild(SilentAim.Config.Hitpart)
and Camera:WorldToViewportPoint(SilentAim.Target.Character[SilentAim.Config.Hitpart].Position)

if AimVector then
Line.Visible=true
Line.Color=SilentAim.LineConfig.Color
Line.Thickness=SilentAim.LineConfig.Thickness
Line.Transparency=SilentAim.LineConfig.Transparency

Line.To=Vector2.new(AimVector.X,AimVector.Y)
Line.From=Vector2.new(SilentAimFOVLocation.X,SilentAimFOVLocation.Y)

if SilentAim.LineConfig.Outline then
LineOutline.Visible=true
LineOutline.Thickness=SilentAim.LineConfig.Thickness+2

LineOutline.To=Vector2.new(AimVector.X,AimVector.Y)
LineOutline.From=Vector2.new(SilentAimFOVLocation.X,SilentAimFOVLocation.Y)
else
LineOutline.Visible=false
end
else
Line.Visible=false
LineOutline.Visible=false
end
else
SilentAim.Line.Visible=false
SilentAim.LineOutline.Visible=false
end
end)

local simulateFirearmProjectile=Utils.GetFunction(
"simulateFirearmProjectile",
Core.Hashes.simulateFirearmProjectile,
"WeaponsProjectilesClient"
)
or LPH_JIT_MAX(function()
local GarbageCollection=getgc(false)
for i=1,#GarbageCollection do local __DARKLUA_CONTINUE_132=false repeat
local v=GarbageCollection[i]

if typeof(v)~="function"then __DARKLUA_CONTINUE_132=true
break
end

local info=debug.getinfo(v)

if not info or typeof(info.source)~="string"or typeof(info.name)~="string"then __DARKLUA_CONTINUE_132=true
break
end

if info.source=="WeaponsProjectilesClient"and info.name=="simulateFirearmProjectile"then
return v
end __DARKLUA_CONTINUE_132=true until true if not __DARKLUA_CONTINUE_132 then break end
end

return nil
end)()

or(function()
local ok,func=pcall(function()
local WeaponsProjectilesClient=Modules:GetModule("WeaponsProjectilesClient",true)
local func=debug.getupvalue(WeaponsProjectilesClient.fireBProjectile,10)
func=debug.getupvalue(func,12)

return func
end)

return ok and type(func)=="function"and func or nil
end)()

assert(type(simulateFirearmProjectile)=="function","simulateFirearmProjectile dependency unavailable")

local LerpDirection,DecideAssist,
























oldsimulateFirearmProjectile=LPH_JIT_MAX(function(CurrentDir,DesiredDir,TurnRate)if CurrentDir:Dot(DesiredDir)<=0 then return CurrentDir end return(CurrentDir+(DesiredDir-CurrentDir)*TurnRate).Unit end),function(Projectile, Enabled, Target, Chance, Roll)if Projectile.__84eAssistDecision==nil then local Probability,Accepted=type(Chance)=="number"and Chance==Chance and math.clamp(Chance,0,100)/100 or 0,false if Enabled and Target then if Probability>=1 then Accepted=true elseif Probability>0 then Accepted=Roll()<Probability end end Projectile.__84eAssistDecision=Accepted if Accepted then Projectile.__Target=Target end end return Projectile.__84eAssistDecision end
oldsimulateFirearmProjectile=Utils.SecureHook(simulateFirearmProjectile,function(BulletTable,DeltaTime,ExtraVelocity)
if not BulletTable.isLocal then
return oldsimulateFirearmProjectile(BulletTable,DeltaTime,ExtraVelocity)
end

local StartPosition,

Assisted=BulletTable.position,DecideAssist(BulletTable,SilentAim.Config.Enabled,
SilentAim.TargetPart and SilentAim.Target,SilentAim.Config.Hitchance,math.random)
if SilentAim.Config.Enabled and SilentAim.TargetPart then
if Assisted then

if BulletTable.__Target then
local character=BulletTable.__Target.Character
local HitPart=character and character:FindFirstChild(SilentAim.Config.Hitpart)

if HitPart then
local CurrentDeltaTime=BulletTable.velocity
local Speed=CurrentDeltaTime.Magnitude

if Speed>0 then
local CurrentDirection,
DesiredDirection=CurrentDeltaTime.Unit,(HitPart.Position-StartPosition).Unit

if CurrentDirection:Dot(DesiredDirection)>0 then
BulletTable.velocity=LerpDirection(
CurrentDirection,
DesiredDirection,
SilentAim.Config.Smoothing
)*Speed
end
end
end
end
end
end

local Result=oldsimulateFirearmProjectile(BulletTable,DeltaTime,ExtraVelocity)

BulletTracers.Add(StartPosition,BulletTable.position)

return Result
end)

return SilentAim end function init.A()local v=init.cache.A if not v then v={c=__modImpl()}init.cache.A=v end return v.c end end do local __modImpl=function()

local Melee={
Config={
Aura=false,
BypassRangeCheck=false,

CustomDamage=false,
CustomDamageAmount=50,

TargetLowHealth=false,

AuraRange=5,
AuraAttackDelay=0.5,

ShowAuraRange=false,
ShowAuraRangeColor=Color3.fromRGB(255,255,255),

ShowAuraTarget=false,
ShowAuraTargetColor=Color3.fromRGB(255,255,255),
},

LastTick=0,
Toggled=false,

RangeLines={},
TargetLines={},

Segments=math.floor(18),
}

for i=1,Melee.Segments do
local Line=Drawing.new"Line"
Line.Visible=false
Line.Thickness=1.5
Melee.RangeLines[i]=Line
end

local Core=init.v()
local Utils,

Modules,
Services=Core.Utils,Core.Modules,Core.Services

local Players=Services.Players
local LocalPlayer,

Camera,

StatesHrpClient,
WeaponsDamageClient,
WeaponsToolbarClient=Players.LocalPlayer,workspace.CurrentCamera,Modules:GetModule("StatesHrpClient",true),Modules:GetModule("WeaponsDamageClient",true),Modules:GetModule("WeaponsToolbarClient",true)

if isfunctionhooked(WeaponsDamageClient.dealMelee)then
restorefunction(WeaponsDamageClient.dealMelee)
end

local checkMelee=Utils.GetFunction("checkMelee",Core.Hashes.checkMelee,"WeaponsDamageClient")
or debug.getupvalue(WeaponsDamageClient.dealMelee,6)

Utils.SecureHook(checkMelee,function(...)
return false
end)

local upvalues=debug.getupvalues(WeaponsDamageClient.dealMelee)
Utils.SecureHook(WeaponsDamageClient.dealMelee,function(Player,Humanoid,Damage)
local IsFlagBearer

if upvalues[2]==true or upvalues[3]~=0 then
IsFlagBearer=Player:GetAttribute"FlagBearer"==true
else
IsFlagBearer=false
end

if IsFlagBearer then
upvalues[4].addBasicMessage"Flag bearer."
return
elseif Humanoid.MaxHealth>100 then
upvalues[4].addBasicMessage"Godded."
return
else
local Root=Humanoid.RootPart

if Root then
local Character=upvalues[7].getPlayerModel(Player)

if Character then
local Buffer,
PlayerUri=buffer.create(3),Character.playerUri

buffer.writeu16(Buffer,0,PlayerUri)
buffer.writeu8(Buffer,2,Damage)

Humanoid.Health=Humanoid.Health-Damage
upvalues[8]:FireServer(Buffer)
upvalues[4].addDamageDelivered(Damage)
end
end
end
end)

Melee.GetEnemyForMelee=LPH_JIT_MAX(function()
if not StatesHrpClient.getHrp()then
return
end

local Distance,Closest,

Players=Melee.Config.AuraRange,{},Players:GetPlayers()

for i=1,#Players do local __DARKLUA_CONTINUE_134=false repeat
local Player=Players[i]

if Player==LocalPlayer then __DARKLUA_CONTINUE_134=true
break
end

if Player.Team==LocalPlayer.Team then __DARKLUA_CONTINUE_134=true
break
end

local Character=Player.Character

if not Character then __DARKLUA_CONTINUE_134=true
break
end

local PrimaryPart=Character:FindFirstChild"HumanoidRootPart"

if not PrimaryPart then __DARKLUA_CONTINUE_134=true
break
end

local Humanoid=Character:FindFirstChild"Humanoid"

if not Humanoid then __DARKLUA_CONTINUE_134=true
break
end

if Humanoid.Health<=0 then __DARKLUA_CONTINUE_134=true
break
end

if Humanoid.MaxHealth>100 then __DARKLUA_CONTINUE_134=true
break
end

local Magnitude=(PrimaryPart.Position-StatesHrpClient.getHrp().Position).Magnitude

if Distance>Magnitude then
table.insert(Closest,{Player=Player,Health=Humanoid.Health})
end __DARKLUA_CONTINUE_134=true until true if not __DARKLUA_CONTINUE_134 then break end
end

if#Closest==0 then
return nil
end

if Melee.Config.TargetLowHealth then
table.sort(Closest,function(a,b)
return a.Health<b.Health
end)
end

return Closest[1].Player
end)

Melee.Update=LPH_JIT_MAX(function()
if not Melee.Config.Aura then
for _,Line in Melee.RangeLines do
Line.Visible=false
end

for _,Line in Melee.TargetLines do
Line.Visible=false
end

return
end

Camera=workspace.CurrentCamera
if not Camera or not StatesHrpClient.getHrp()then
for _,line in Melee.RangeLines do line.Visible=false end
for _,line in Melee.TargetLines do line.Visible=false end
return
end

local Enemy=Melee.GetEnemyForMelee()

if Melee.Config.ShowAuraRange then
if LocalPlayer.Character and LocalPlayer.Character.PrimaryPart then
local Points={}

for Angle=0,360,20 do
local Rad=math.rad(Angle)
local Pos=LocalPlayer.Character.PrimaryPart.Position
+Vector3.new(math.cos(Rad)*Melee.Config.AuraRange,0,math.sin(Rad)*Melee.Config.AuraRange)
local Screen=Camera:WorldToViewportPoint(Pos)

if Screen.Z>0 then
Points[Angle/20+1]=Vector2.new(Screen.X,Screen.Y)
end
end

for i=1,Melee.Segments do
local A,
B,
Line=Points[i],Points[i+1],Melee.RangeLines[i]

if A and B then
Line.Visible=true
Line.Color=Melee.Config.ShowAuraRangeColor
Line.From=A
Line.To=B
else
Line.Visible=false
end
end
else
for _,Line in Melee.RangeLines do
Line.Visible=false
end
end
else
for _,Line in Melee.RangeLines do
Line.Visible=false
end
end

if Melee.Config.ShowAuraTarget then
for _,Line in Melee.TargetLines do
Line.Visible=false
end

local Players=Players:GetPlayers()

for i=1,#Players do local __DARKLUA_CONTINUE_144=false repeat
local Player=Players[i]

if Enemy~=Player then __DARKLUA_CONTINUE_144=true
break
end

if not(Player.Character and Player.Character.PrimaryPart and LocalPlayer.Character and LocalPlayer.Character.PrimaryPart and Melee.TargetLines[Player])then __DARKLUA_CONTINUE_144=true break end
local To,OnScreen=Camera:WorldToViewportPoint(Player.Character.PrimaryPart.Position)
local To2,OnScreen2=Camera:WorldToViewportPoint(LocalPlayer.Character.PrimaryPart.Position)

if OnScreen and OnScreen2 then
Melee.TargetLines[Player].Visible=true
Melee.TargetLines[Player].Color=Melee.Config.ShowAuraTargetColor
Melee.TargetLines[Player].From=Vector2.new(To2.X,To2.Y)
Melee.TargetLines[Player].To=Vector2.new(To.X,To.Y)
else
Melee.TargetLines[Player].Visible=false
end __DARKLUA_CONTINUE_144=true until true if not __DARKLUA_CONTINUE_144 then break end
end
else
for _,Line in Melee.TargetLines do
Line.Visible=false
end
end

if
getgenv().Options and getgenv().Options.MeleeAuraBind and getgenv().Options.MeleeAuraBind:GetState()
or Melee.Toggled
then
if os.clock()-Melee.LastTick>=Melee.Config.AuraAttackDelay then
if Enemy then
if not Melee.Config.CustomDamage then
local Client=WeaponsToolbarClient.getEquippedWeaponClient()

if Client and Client.meleeAction then
Utils.SecureCall(
WeaponsDamageClient.dealMelee,
Modules:GetModule"WeaponsDamageClient",
Enemy,
Enemy.Character.Humanoid,
Client.meleeAction:GetDamage()
)
end
else
Utils.SecureCall(
WeaponsDamageClient.dealMelee,
Modules:GetModule"WeaponsDamageClient",
Enemy,
Enemy.Character.Humanoid,
Melee.Config.CustomDamageAmount
)
end
end

Melee.LastTick=os.clock()
end
end
end)

Melee.CreateLine=LPH_JIT_MAX(function(Player)
if Melee.TargetLines[Player]then Utils.Dispose(Melee.TargetLines[Player])end
local Line=Drawing.new"Line"
Line.Visible=false
Line.Thickness=1.5
Line.Color=Color3.new(1,1,1)

Melee.TargetLines[Player]=Line
end)

return Melee end function init.B()local v=init.cache.B if not v then v={c=__modImpl()}init.cache.B=v end return v.c end end do local __modImpl=function()

return{
HitboxExtender=init.y(),
SilentAim=init.A(),
MeleeAura=init.B(),
}end function init.C()local v=init.cache.C if not v then v={c=__modImpl()}init.cache.C=v end return v.c end end do local __modImpl=function()
local Core,
Network=init.v(),init.x()

local Utils,
Modules,
Services,
Variables=Core.Utils,Core.Modules,Core.Services,Core.Variables

local Players=Services.Players
local LocalPlayer,

FlagRig,

Flag,







OldPromptTriggered=Players.LocalPlayer,Modules:GetModule("FlagRig",true),{Config={InstantCapture=false,InstantRespawn=false,NoSpawnConditions=false,},}
OldPromptTriggered=Utils.SecureHook(FlagRig.PromptTriggered,function(self)
if Flag.Config.InstantCapture then
return
end
return OldPromptTriggered(self)
end)

local OldPromptBegan=FlagRig.PromptBegan
FlagRig.PromptBegan=function(self)
if self.originalHoldDuration==nil then self.originalHoldDuration=self.prompt.HoldDuration end
if Flag.Config.InstantCapture and not LocalPlayer:GetAttribute"FlagBearer"then
self.prompt.HoldDuration=0
self.promptBeganTime=nil
Network:FireEvent("EquipFlag",nil,self.flagModel)
return
end

self.prompt.HoldDuration=self.originalHoldDuration or self.prompt.HoldDuration

return OldPromptBegan(self)
end

Flag.Update=LPH_JIT_MAX(function()
if Flag.Config.InstantRespawn or Flag.Config.NoSpawnConditions then
Variables.SetVariable("FlagHoldToSpawnTime",0)
else
Variables.SetVariable("FlagHoldToSpawnTime",nil,true)
end
if Flag.Config.InstantRespawn then
Variables.SetVariable("TimeAliveSpawn",true)
Variables.SetVariable("SkirmishRespawnTime",0)
else
Variables.SetVariable("TimeAliveSpawn",nil,true)
Variables.SetVariable("SkirmishRespawnTime",nil,true)
end

if Flag.Config.NoSpawnConditions then
Variables.SetVariable("FlagMustBeHeld",false)
Variables.SetVariable("FlagEnemiesMaximum",0)
Variables.SetVariable("ContestAntiSpawnRange",0)
Variables.SetVariable("ProtectedMainSpawnRadius",0)
Variables.SetVariable("FlagEnemiesRange",0)
Variables.SetVariable("FlagEnemiesFarRange",math.huge)
Variables.SetVariable("FlagAlliesRange",math.huge)
Variables.SetVariable("FlagLostTime",0)
Variables.SetVariable("FlagRespawnTime",0)
Variables.SetVariable("FlagNearRange",math.huge)
Variables.SetVariable("FlagFarRange",0)
else
Variables.SetVariable("FlagMustBeHeld",nil,true)
Variables.SetVariable("FlagEnemiesMaximum",nil,true)
Variables.SetVariable("ContestAntiSpawnRange",nil,true)
Variables.SetVariable("ProtectedMainSpawnRadius",nil,true)
Variables.SetVariable("FlagEnemiesRange",nil,true)
Variables.SetVariable("FlagEnemiesFarRange",nil,true)
Variables.SetVariable("FlagAlliesRange",nil,true)
Variables.SetVariable("FlagLostTime",nil,true)
Variables.SetVariable("FlagRespawnTime",nil,true)
Variables.SetVariable("FlagNearRange",nil,true)
Variables.SetVariable("FlagFarRange",nil,true)
end
end)init.b()

.Add(function()FlagRig.PromptBegan=OldPromptBegan end)
return Flag end function init.D()local v=init.cache.D if not v then v={c=__modImpl()}init.cache.D=v end return v.c end end do local __modImpl=function()

local Core,
Network=init.v(),init.x()

local Modules=Core.Modules
local CombatFormationClient,

Godmode=Modules:GetModule("CombatFormationClient",true),{}

Godmode.OnEnable=LPH_JIT_MAX(function()
Network:AddBlacklist"RegisterDeath"
end)

Godmode.OnDisable=LPH_JIT_MAX(function()
Network:RemoveBlacklist"RegisterDeath"

local Buffer=buffer.create(1)
buffer.writeu8(Buffer,0,CombatFormationClient.formation)
Network:FireEvent("RegisterDeath",nil,Buffer)
end)

return Godmode end function init.E()local v=init.cache.E if not v then v={c=__modImpl()}init.cache.E=v end return v.c end end do local __modImpl=function()

local Mods,





















Core={Shooting={NoRecoil=false,NoSpread=false,NoMisfires=false,InstantAim=false,IgnoreReloadPenalties=false,},Melee={SetDamage=false,SetDamageAmount=1,},Misc={CavInfStamina=false,NoMoralLossFromShots=false,RemoveMoraleCameraShake=false,NoMoralLossFromCannonFire=false,},},init.v()


local Utils,
Modules,
Variables,
Runtime=Core.Utils,Core.Modules,Core.Variables,init.b()

local FireActionClient,
MeleeActionClient,
CombatMoraleClient,
CombatRecoilClient=Modules:GetModule("FireActionClient",true),Modules:GetModule("MeleeActionClient",true),Modules:GetModule("CombatMoraleClient",true),Modules:GetModule("CombatRecoilClient",true)


local Shake,













OldShake=((LPH_JIT_MAX(function()local upvalues=debug.getupvalues(CombatRecoilClient.start)for _,v in upvalues do local __DARKLUA_CONTINUE_146=false repeat if typeof(v)~="function"then __DARKLUA_CONTINUE_146=true break end return v until true if not __DARKLUA_CONTINUE_146 then break end end return nil end))())
OldShake=Utils.SecureHook(Shake,function(...)
if Mods.Misc.RemoveMoraleCameraShake then
return
end

return OldShake(...)
end)

local OldGetDamage=MeleeActionClient.GetDamage
MeleeActionClient.GetDamage=Utils.SecureHook(MeleeActionClient.GetDamage,function(self)
if Mods.Melee.SetDamage then
return Mods.Melee.SetDamageAmount
end

return OldGetDamage(self)
end)

local OldShakeFiredShot
OldShakeFiredShot=Utils.SecureHook(CombatRecoilClient.shakeFiredShot,function(...)
if Mods.Shooting.NoRecoil then
return
end

return OldShakeFiredShot(...)
end)

local OldGetMisfired
OldGetMisfired=Utils.SecureHook(CombatMoraleClient.getMisfired,function(...)
if Mods.Shooting.NoMisfires then
return false,false
end

return OldGetMisfired(...)
end)

local OldBulletPass
OldBulletPass=Utils.SecureHook(CombatMoraleClient.bulletPass,function(...)
if Mods.Misc.NoMoralLossFromShots then
return
end

return OldBulletPass(...)
end)

local OldCannonPassMoraleShock
OldCannonPassMoraleShock=Utils.SecureHook(CombatMoraleClient.cannonPassMoraleShock,function(...)
if Mods.Misc.NoMoralLossFromCannonFire then
return
end

return OldCannonPassMoraleShock(...)
end)

Mods.Update=LPH_JIT_MAX(function()
if Mods.Misc.CavInfStamina then
Variables.SetVariable("HorseStaminaLoss",0)
Variables.SetVariable("HorseStaminaGain",100)
Variables.SetVariable("HorseStaminaGainMaxSpeed",50)
else
Variables.SetVariable("HorseStaminaGain",nil,true)
Variables.SetVariable("HorseStaminaLoss",nil,true)
Variables.SetVariable("HorseStaminaGainMaxSpeed",nil,true)
end
end)



local OldRenderStepped
OldRenderStepped=Utils.SecureHook(FireActionClient.RenderStepped,function(self,...)
if Runtime.Alive then
local ok,err=pcall(function()
if Mods.Shooting.InstantAim then
self.aimTime=1
self.realAimTime=1
end
Variables.SetVariable("ReloadWalkPenalty",Mods.Shooting.IgnoreReloadPenalties and 0 or nil,
not Mods.Shooting.IgnoreReloadPenalties)
end)
if not ok then Runtime.Record("weapon update",err)end
end



















return OldRenderStepped(self,...)
end)

local OldFire
OldFire=Utils.SecureHook(FireActionClient.Fire,function(self)
if Mods.Shooting.NoSpread then
Variables.SetVariable("ProjectileSpread",0)
else
Variables.SetVariable("ProjectileSpread",nil,true)
end

return OldFire(self)
end)

return Mods end function init.F()local v=init.cache.F if not v then v={c=__modImpl()}init.cache.F=v end return v.c end end do local __modImpl=function()

local Core,
Network=init.v(),init.x()

local Utils,
Modules=Core.Utils,Core.Modules

local ChantActionClient,
CombatKillfeedClient,
CheeringActionClient,
RequiredCharacterSoundsClient,
UnrequiredCharacterSoundsClient=Modules:GetModule("ChantActionClient",true),Modules:GetModule("CombatKillfeedClient",true),Modules:GetModule("CheeringActionClient",true),Modules:GetModule("CharacterSoundsClient",true),Modules:GetModule("CharacterSoundsClient",false)

local ChantSets,

LocalPlayer=Modules:GetModule("ChantSets",true)or debug.getupvalue(ChantActionClient.start,5),Core.Services.Players.LocalPlayer

local Chants={
Sets=ChantSets,
Config={
SpamEnabled=false,
EmoteEnabled=false,
Delay=2.5,

SelectedGender="Male",
SelectedNation="Italian",
SelectedChantSet="Carica!",
},

Nations=(function()
local self={}

for Index,Value in ChantSets do
if Value.Male and Value.Male.chants then
table.insert(self,Index)
end
end

table.sort(self)

table.insert(self,1,"Random")

return self
end)(),

LastTick=0,
}

Chants.Chant=LPH_JIT_MAX(function()
if type(Chants.Config.SelectedNation)~="string"then return end
if Chants.Config.SelectedNation=="Random"and#Chants.Nations<2 then return end
local Nation=Chants.Config.SelectedNation=="Random"
and Chants.Nations[math.random(2,#Chants.Nations)]
or Chants.Config.SelectedNation

if not Nation or not ChantSets[Nation]then
print"No valid nation selected for ChantSpam!"
return
end

local NationData=ChantSets[Nation]

if not NationData then
return
end

local Gender

if Chants.Config.SelectedGender=="Random"then
local hasMale,
hasFemale=NationData.Male and NationData.Male.chants,NationData.Female and NationData.Female.chants

if hasMale and hasFemale then
Gender=math.random(1,2)==1 and"Male"or"Female"
elseif hasMale then
Gender="Male"
elseif hasFemale then
Gender="Female"
else
return
end
else
Gender=Chants.Config.SelectedGender

if not NationData[Gender]or not NationData[Gender].chants then
return
end
end

local GenderData=NationData[Gender]
local ChantGroups=GenderData.chants

if not ChantGroups or#ChantGroups==0 then
return
end

local Group

if Chants.Config.SelectedChantSet=="Random"then
Group=ChantGroups[math.random(1,#ChantGroups)]
else
for i=1,#ChantGroups do
local group=ChantGroups[i]

if group.groupname==Chants.Config.SelectedChantSet then
Group=group
break
end
end
end

if not Group or not Group.chants or#Group.chants==0 then
return
end

local Selected=Group.chants[math.random(#Group.chants)]

if not Selected then
return
end

task.defer(function()
Utils.SecureCall(RequiredCharacterSoundsClient.playerChanted,UnrequiredCharacterSoundsClient,LocalPlayer,Selected.enumeration)
end)

if Chants.Config.EmoteEnabled then
CheeringActionClient.cheer()
end

CombatKillfeedClient.addBasicMessage(Selected.voice,Color3.fromRGB(221,135,255))

local Buffer=buffer.create(2)
buffer.writeu16(Buffer,0,Selected.enumeration)
Network:FireEvent("Chant",1,Buffer)
end)

Chants.Update=LPH_JIT_MAX(function()
if not Chants.Config.SpamEnabled then
return
end

local Time=os.clock()

if os.clock()-Chants.LastTick>=Chants.Config.Delay then
Chants.LastTick=Time
Chants.Chant()
end
end)

return Chants end function init.G()local v=init.cache.G if not v then v={c=__modImpl()}init.cache.G=v end return v.c end end do local __modImpl=function()
local Services=init.v().Services
local Players,
UserInputService=Services.Players,Services.UserInputService

local LocalPlayer=Players.LocalPlayer
local Mouse,

Movement=LocalPlayer:GetMouse(),{
Config={
Fly=false,
FlyToggled=false,
FlySpeed=1,

Speed=false,
SpeedToggled=false,
SpeedAmount=1,

ClickTP=false,
ClickTPBind=Enum.KeyCode.F15,
},
}

Movement.Update=LPH_JIT_MAX(function(DeltaTime)
if not(LocalPlayer.Character and LocalPlayer.Character.PrimaryPart)then
return
end

local Humanoid=LocalPlayer.Character:FindFirstChild"Humanoid"

if not Humanoid then
return
end

local PrimaryPart=LocalPlayer.Character.PrimaryPart

if Movement.Config.Fly and getgenv().Options.FlyBind and getgenv().Options.FlyBind:GetState()then
local Vertical=0

if UserInputService:IsKeyDown(Enum.KeyCode.Space)then
Vertical=Movement.Config.FlySpeed*3.75*DeltaTime
elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)then
Vertical=-Movement.Config.FlySpeed*3.75*DeltaTime
end

PrimaryPart.CFrame=PrimaryPart.CFrame+(Humanoid.MoveDirection*Movement.Config.FlySpeed*10*DeltaTime)
PrimaryPart.CFrame=PrimaryPart.CFrame+Vector3.new(0,Vertical,0)
PrimaryPart.Velocity=Vector3.new(PrimaryPart.Velocity.X*0.5,1.9,PrimaryPart.Velocity.Z*0.5)
end

if Movement.Config.Speed and getgenv().Options.SpeedBind and getgenv().Options.SpeedBind:GetState()then
PrimaryPart.CFrame=PrimaryPart.CFrame+Humanoid.MoveDirection*Movement.Config.SpeedAmount*60*DeltaTime
end
end)

Movement.ClickTP=LPH_JIT_MAX(function()
if not Movement.Config.ClickTP then
return
end

if not(LocalPlayer.Character and LocalPlayer.Character.PrimaryPart)then
return
end

local PrimaryPart,
TargetPosition=LocalPlayer.Character.PrimaryPart,Mouse.Hit.Position

TargetPosition=TargetPosition+Vector3.new(0,5,0)
PrimaryPart.CFrame=CFrame.lookAt(TargetPosition,TargetPosition+PrimaryPart.CFrame.LookVector)
end)init.b()

.Give(Mouse.Button1Down:Connect(LPH_JIT_MAX(function()
local key=Movement.Config.ClickTPBind
if typeof(key)=="EnumItem"and key.EnumType==Enum.KeyCode and not UserInputService:GetFocusedTextBox()and UserInputService:IsKeyDown(key)then
Movement.ClickTP()
end
end)))

return Movement end function init.H()local v=init.cache.H if not v then v={c=__modImpl()}init.cache.H=v end return v.c end end do local __modImpl=function()
return{
FlagMods=init.D(),
Godmode=init.E(),
WeaponMods=init.F(),
Chants=init.G(),
Movement=init.H(),
}end function init.I()local v=init.cache.I if not v then v={c=__modImpl()}init.cache.I=v end return v.c end end do local __modImpl=function()
local Owner={}
Owner.__index=Owner

function Owner.new()
return setmetatable({Objects={}},Owner)
end

function Owner.Set(self,instance,property,value)
if not instance or value==nil then return end
local properties=self.Objects[instance]
if not properties then properties={}self.Objects[instance]=properties end
local record=properties[property]
if not record then
record={Baseline=instance[property],Last=nil,Writing=false}
properties[property]=record
record.Connection=instance:GetPropertyChangedSignal(property):Connect(function()
if record.Writing then return end
if instance[property]==record.Last then return end
record.Baseline=instance[property]
record.Last=nil
end)
end
if record.Last~=nil and instance[property]~=record.Last then record.Baseline=instance[property]end
if instance[property]==value then record.Last=value return end
local prior=record.Last
record.Last=value
record.Writing=true
local ok,err=pcall(function()instance[property]=value end)
record.Writing=false
if not ok then record.Last=prior error(err,0)end
record.Last=value
end

function Owner.Release(self,instance,property)
local properties=self.Objects[instance]
local record=properties and properties[property]
if not record then return end
record.Connection:Disconnect()

local ok,current=pcall(function()return instance[property]end)
if ok and record.Last~=nil and current==record.Last then
pcall(function()instance[property]=record.Baseline end)
end
properties[property]=nil
if next(properties)==nil then self.Objects[instance]=nil end
end

function Owner.Reconcile(self,wanted)
local releases={}
for instance,properties in self.Objects do
for property in properties do
if not wanted[instance]or wanted[instance][property]==nil then
table.insert(releases,{instance,property})
end
end
end
for _,item in releases do self:Release(item[1],item[2])end
for instance,properties in wanted do
for property,value in properties do self:Set(instance,property,value)end
end
end

function Owner.Stop(self)
self:Reconcile{}
end

return Owner end function init.J()local v=init.cache.J if not v then v={c=__modImpl()}init.cache.J=v end return v.c end end do local __modImpl=function()

local Core=init.v()
local Lighting,
HttpService,
Owner=Core.Services.Lighting,Core.Services.HttpService,init.J().new()
local SkyboxPresets,












World,






Preview={Stars=HttpService:JSONDecode'{"SkyboxRt":"rbxassetid://197804745","SkyboxLf":"rbxassetid://197803346","SkyboxUp":"rbxassetid://197802608","SunTextureId":"rbxassetid://5392574622","MoonTextureId":"rbxassetid://62326944","SkyboxFt":"rbxassetid://197801843","SkyboxBk":"rbxassetid://197800582","SkyboxDn":"rbxassetid://197801240"}',Nebula=HttpService:JSONDecode'{"SkyboxRt":"rbxassetid://87408857415924","SkyboxLf":"rbxassetid://73372229972523","SkyboxUp":"rbxassetid://137817405681365","SunTextureId":"rbxassetid://5392574622","MoonTextureId":"rbxassetid://62326944","SkyboxFt":"rbxassetid://104400530594543","SkyboxBk":"rbxassetid://129876530632297","SkyboxDn":"rbxassetid://108406529909981"}',Winter=HttpService:JSONDecode'{"SkyboxRt":"http://www.roblox.com/asset/?id=155657619","SkyboxLf":"http://www.roblox.com/asset/?id=155657671","SkyboxUp":"http://www.roblox.com/asset/?id=155674931","SunTextureId":"rbxassetid://5392574622","MoonTextureId":"rbxassetid://62326944","SkyboxFt":"http://www.roblox.com/asset/?id=155657609","SkyboxBk":"http://www.roblox.com/asset/?id=155657655","SkyboxDn":"http://www.roblox.com/asset/?id=155674246"}',Lean=HttpService:JSONDecode'{"SkyboxRt":"http://www.roblox.com/asset/?id=433274429","SkyboxLf":"http://www.roblox.com/asset/?id=433274370","SkyboxUp":"http://www.roblox.com/asset/?id=433274285","SunTextureId":"rbxassetid://5392574622","MoonTextureId":"rbxassetid://62326944","SkyboxFt":"http://www.roblox.com/asset/?id=433274131","SkyboxBk":"http://www.roblox.com/asset/?id=433274085","SkyboxDn":"http://www.roblox.com/asset/?id=433274194"}',Dark=HttpService:JSONDecode'{"SkyboxRt":"http://www.roblox.com/asset/?id=171410657","SkyboxLf":"http://www.roblox.com/asset/?id=171410666","SkyboxUp":"http://www.roblox.com/asset/?id=171410636","SunTextureId":"rbxassetid://5392574622","MoonTextureId":"rbxassetid://62326944","SkyboxFt":"http://www.roblox.com/asset/?id=171410620","SkyboxBk":"http://www.roblox.com/asset/?id=171410628","SkyboxDn":"http://www.roblox.com/asset/?id=171410649"}',},{Enabled=false,CustomSkyBox=false,CustomSkyBoxId="Default",CustomAmbience=false,Ambient=Color3.new(1,1,1),OutdoorAmbient=Color3.new(1,1,1),ColorShift_Top=Color3.new(1,1,1),ColorShift_Bottom=Color3.new(1,1,1),CustomFog=false,FogStart=150,FogEnd=10000,FogColor=Color3.new(1,1,1),CustomTime=false,CustomTimeNum=12,ClearAtmosphere=false,}

function World.Restore()Owner:Stop()end

function World.Capture()
local result={}
for key,value in World do
if type(value)~="function"then result[key]=value end
end
return result
end

function World.BeginPreview()
if not Preview then Preview=World.Capture()end
end

function World.ApplyPreview()Preview=nil end

function World.CancelPreview()
if not Preview then return end
for key,value in Preview do World[key]=value end
Preview=nil
World.Update()
end

World.Update=LPH_JIT_MAX(function()
if not World.Enabled then World.Restore()return end
local wanted,
values={},{}
if World.CustomAmbience then
for _,key in{"Ambient","OutdoorAmbient","ColorShift_Top","ColorShift_Bottom"}do values[key]=World[key]end
end
if World.CustomFog then
values.FogStart=math.min(World.FogStart,World.FogEnd)
values.FogEnd=World.FogEnd
values.FogColor=World.FogColor
end
if World.CustomTime then values.ClockTime=math.clamp(World.CustomTimeNum,0,24)end
if next(values)then wanted[Lighting]=values end
local sky=Lighting:FindFirstChildOfClass"Sky"
if sky and World.CustomSkyBox and SkyboxPresets[World.CustomSkyBoxId]then
wanted[sky]=SkyboxPresets[World.CustomSkyBoxId]
end
local atmosphere=Lighting:FindFirstChildOfClass"Atmosphere"
if atmosphere and World.ClearAtmosphere then wanted[atmosphere]={Density=0,Haze=0,Glare=0}end
Owner:Reconcile(wanted)
end)init.b()

.Add(World.Restore)
return World end function init.K()local v=init.cache.K if not v then v={c=__modImpl()}init.cache.K=v end return v.c end end do local __modImpl=function()

return{
World=init.K(),
BulletTracers=init.z(),
}end function init.L()local v=init.cache.L if not v then v={c=__modImpl()}init.cache.L=v end return v.c end end do local __modImpl=function()
return{
Combat=init.C(),
Misc=init.I(),
Visuals=init.L()
}end function init.M()local v=init.cache.M if not v then v={c=__modImpl()}init.cache.M=v end return v.c end end do local __modImpl=function()
return{
Core=init.v(),
Network=init.x(),
Utils=init.t(),
Features=init.M(),
}end function init.N()local v=init.cache.N if not v then v={c=__modImpl()}init.cache.N=v end return v.c end end do local __modImpl=function()



local httpService,
Storage,
ThemeManager,
ThemeFields=game:GetService"HttpService",init.c(),{},{"FontColor","MainColor","AccentColor","BackgroundColor","OutlineColor","RiskColor","DisabledColor"}

LPH_NO_VIRTUALIZE(function()local
Options, 
Toggles=getgenv().Options, getgenv().Toggles

do
ThemeManager.Folder="84e Client/Themes"


ThemeManager.Library=nil
ThemeManager.BuiltInThemes={Default=
{
1,
httpService:JSONDecode
'{"FontColor":"e7eaf1","MainColor":"191c23","AccentColor":"e14d5b","BackgroundColor":"11141a","OutlineColor":"303642"}'
,
},BBot=
{
2,
httpService:JSONDecode
'{"FontColor":"ffffff","MainColor":"1e1e1e","AccentColor":"7e48a3","BackgroundColor":"232323","OutlineColor":"141414"}'
,
},Fatality=
{
3,
httpService:JSONDecode
'{"FontColor":"ffffff","MainColor":"1e1842","AccentColor":"c50754","BackgroundColor":"191335","OutlineColor":"3c355d"}'
,
},Jester=
{
4,
httpService:JSONDecode
'{"FontColor":"ffffff","MainColor":"242424","AccentColor":"db4467","BackgroundColor":"1c1c1c","OutlineColor":"373737"}'
,
},Mint=
{
5,
httpService:JSONDecode
'{"FontColor":"ffffff","MainColor":"242424","AccentColor":"3db488","BackgroundColor":"1c1c1c","OutlineColor":"373737"}'
,
},
["Tokyo Night"]={
6,
httpService:JSONDecode
'{"FontColor":"ffffff","MainColor":"191925","AccentColor":"6759b3","BackgroundColor":"16161f","OutlineColor":"323232"}'
,
},Ubuntu=
{
7,
httpService:JSONDecode
'{"FontColor":"ffffff","MainColor":"3e3e3e","AccentColor":"e2581e","BackgroundColor":"323232","OutlineColor":"191919"}'
,
},Quartz=
{
8,
httpService:JSONDecode
'{"FontColor":"ffffff","MainColor":"232330","AccentColor":"426e87","BackgroundColor":"1d1b26","OutlineColor":"27232f"}'
,
},
}

function ThemeManager.ApplyTheme(self,theme)
if type(theme)~="string"then return false,"select a theme"end
local customThemeData=self:GetCustomTheme(theme)
local data=customThemeData or self.BuiltInThemes[theme]

if not data then
return
end



local scheme=data[2]
for idx,col in next,customThemeData or scheme do local __DARKLUA_CONTINUE_157=false repeat
if not table.find(ThemeFields,idx)then __DARKLUA_CONTINUE_157=true break end
self.Library[idx]=Color3.fromHex(col)

if Options[idx]then
Options[idx]:SetValueRGB(Color3.fromHex(col))
end __DARKLUA_CONTINUE_157=true until true if not __DARKLUA_CONTINUE_157 then break end
end

self:ThemeUpdate()
end

function ThemeManager.ThemeUpdate(self)

local options={"FontColor","MainColor","AccentColor","BackgroundColor","OutlineColor","RiskColor","DisabledColor"}
for i,field in next,options do
if Options and Options[field]then
self.Library[field]=Options[field].Value
end
end

self.Library.AccentColorDark=self.Library:GetDarkerColor(self.Library.AccentColor)
self.Library:UpdateColorsUsingRegistry()
end

function ThemeManager.LoadDefault(self)
local theme,
readOk,content="Default",Storage.Read(self.Folder.."/themes/default.txt")
if not readOk then content=nil end

local isDefault=true
if content then
if self.BuiltInThemes[content]then
theme=content
elseif self:GetCustomTheme(content)then
theme=content
isDefault=false
end
elseif self.BuiltInThemes[self.DefaultTheme]then
theme=self.DefaultTheme
end

if isDefault and Options.ThemeManager_ThemeList then
Options.ThemeManager_ThemeList:SetValue(theme)
else
self:ApplyTheme(theme)
end
end

function ThemeManager.SaveDefault(self,theme)
local ok,err=Storage.Write(self.Folder.."/themes/default.txt",theme)
if not ok then self.Library:Notify("Default theme save failed: "..tostring(err))end
return ok,err
end

function ThemeManager.CreateThemeManager(self,groupbox)
groupbox
:AddLabel"Background color"
:AddColorPicker("BackgroundColor",{Default=self.Library.BackgroundColor})
groupbox:AddLabel"Main color":AddColorPicker("MainColor",{Default=self.Library.MainColor})
groupbox:AddLabel"Accent color":AddColorPicker("AccentColor",{Default=self.Library.AccentColor})
groupbox:AddLabel"Outline color":AddColorPicker("OutlineColor",{Default=self.Library.OutlineColor})
groupbox:AddLabel"Font color":AddColorPicker("FontColor",{Default=self.Library.FontColor})
groupbox:AddLabel"Risk color":AddColorPicker("RiskColor",{Default=self.Library.RiskColor})
groupbox:AddLabel"Disabled color":AddColorPicker("DisabledColor",{Default=self.Library.DisabledColor})

local ThemesArray={}
for Name,Theme in next,self.BuiltInThemes do
table.insert(ThemesArray,Name)
end

table.sort(ThemesArray,function(a,b)
return self.BuiltInThemes[a][1]<self.BuiltInThemes[b][1]
end)

groupbox:AddDivider()
groupbox:AddDropdown("ThemeManager_ThemeList",{Text="Theme list",Values=ThemesArray,Default=1})

groupbox:AddButton("Set as default",function()
self:SaveDefault(Options.ThemeManager_ThemeList.Value)
self.Library:Notify(string.format("Set default theme to %q",Options.ThemeManager_ThemeList.Value))
end)

Options.ThemeManager_ThemeList:OnChanged(function()
self:ApplyTheme(Options.ThemeManager_ThemeList.Value)
end)

groupbox:AddDivider()
groupbox:AddInput("ThemeManager_CustomThemeName",{Text="Custom theme name"})
groupbox:AddDropdown(
"ThemeManager_CustomThemeList",
{Text="Custom themes",Values=self:ReloadCustomThemes(),AllowNull=true,Default=1}
)
groupbox:AddDivider()

groupbox
:AddButton("Save theme",function()
self:SaveCustomTheme(Options.ThemeManager_CustomThemeName.Value)

Options.ThemeManager_CustomThemeList:SetValues(self:ReloadCustomThemes())
Options.ThemeManager_CustomThemeList:SetValue(nil)
end)
:AddButton("Load theme",function()
self:ApplyTheme(Options.ThemeManager_CustomThemeList.Value)
end)

groupbox:AddButton("Refresh list",function()
Options.ThemeManager_CustomThemeList:SetValues(self:ReloadCustomThemes())
Options.ThemeManager_CustomThemeList:SetValue(nil)
end)

groupbox:AddButton("Set as default",function()
if
Options.ThemeManager_CustomThemeList.Value~=nil
and Options.ThemeManager_CustomThemeList.Value~=""
then
self:SaveDefault(Options.ThemeManager_CustomThemeList.Value)
self.Library:Notify(
string.format("Set default theme to %q",Options.ThemeManager_CustomThemeList.Value)
)
end
end)

ThemeManager:LoadDefault()local UpdateTheme=function()


self:ThemeUpdate()end


Options.BackgroundColor:OnChanged(UpdateTheme)
Options.MainColor:OnChanged(UpdateTheme)
Options.AccentColor:OnChanged(UpdateTheme)
Options.OutlineColor:OnChanged(UpdateTheme)
Options.FontColor:OnChanged(UpdateTheme)
Options.RiskColor:OnChanged(UpdateTheme)
Options.DisabledColor:OnChanged(UpdateTheme)
end

function ThemeManager.GetCustomTheme(self,file)
if type(file)~="string"then return nil end
local stem=file:sub(-5)==".json"and file:sub(1,-6)or file
if not Storage.ValidName(stem)then return nil end
local ok,data=Storage.Read(self.Folder.."/themes/"..stem..".json")
if not ok then return nil end
local decoded
ok,decoded=pcall(function()return httpService:JSONDecode(data)end)
if not ok or type(decoded)~="table"then return nil end
local result={}
for _,field in ThemeFields do
local value=decoded[field]
if value~=nil then
if type(value)~="string"or not value:match"^%x%x%x%x%x%x$"then return nil end
result[field]=value
end
end
return next(result)and result or nil
end

function ThemeManager.SaveCustomTheme(self,file)
if not Storage.ValidName(file)then return self.Library:Notify("Invalid theme name",3)end
local ok,encoded=pcall(function()
local theme={}
for _,field in ThemeFields do theme[field]=Options[field].Value:ToHex()end
return httpService:JSONEncode(theme)
end)
if not ok then return self.Library:Notify("Theme encode failed: "..tostring(encoded))end
local saved,err=Storage.Write(self.Folder.."/themes/"..file..".json",encoded)
if not saved then self.Library:Notify("Theme save failed: "..tostring(err))end
return saved,err
end

function ThemeManager.ReloadCustomThemes(self)
local ok,names=Storage.List(self.Folder.."/themes",".json")
if not ok then return{}end
for index,name in names do names[index]=name..".json"end
return names
end

function ThemeManager.SetLibrary(self,lib)
self.Library=lib
end

function ThemeManager.BuildFolderTree(self)
local ok,err=Storage.MakeFolders(self.Folder.."/themes")
if not ok and self.Library then self.Library:Notify("Theme storage unavailable: "..tostring(err))end
return ok,err
end

function ThemeManager.SetFolder(self,folder)
self.Folder=folder
self:BuildFolderTree()
end

function ThemeManager.CreateGroupBox(self,tab)
assert(self.Library,"Must set ThemeManager.Library first!")
return tab:AddLeftGroupbox"Themes"
end

function ThemeManager.ApplyToTab(self,tab)
assert(self.Library,"Must set ThemeManager.Library first!")
local groupbox=self:CreateGroupBox(tab)
self:CreateThemeManager(groupbox)
end

function ThemeManager.ApplyToGroupbox(self,groupbox)
assert(self.Library,"Must set ThemeManager.Library first!")
self:CreateThemeManager(groupbox)
end

ThemeManager:BuildFolderTree()
end
end)()

return ThemeManager end function init.O()local v=init.cache.O if not v then v={c=__modImpl()}init.cache.O=v end return v.c end end do local __modImpl=function()

local loadDeadline=os.clock()+30
while not game:IsLoaded()do
if os.clock()>=loadDeadline then error"Game loading exceeded 30 seconds"end
task.wait()
end

local Runtime,
Assets,
oldSession=init.b(),init.f(),getgenv().Client84eSession
if oldSession and oldSession.Stop then pcall(oldSession.Stop)end
if not Runtime.Alive then error"Restart requires a fresh bundle evaluation"end
getgenv().Client84eSession=Runtime

local Preflight=init.g()
local ready,
libs=Preflight.Check(),init.j()
local baseLibrary=libs.Library
Runtime.Add(function()baseLibrary:Unload()end)
baseLibrary:OnUnload(Runtime.Stop)
local Panels=init.n()
if not ready then
baseLibrary.StandardCursor=true
local window,
manager=baseLibrary:CreateWindow{Title="84e Client — readiness",Center=true,AutoShow=true},init.o()
manager:SetLibrary(baseLibrary)
manager:SetFolder"84e Client/NW"
Panels.Build(baseLibrary,window,manager,{})
return nil
end
local checkpoint,
initialized,modules=Runtime.Checkpoint(),pcall(function()return init.N()end)
if not initialized then
Runtime.Record("initialization",modules)
Runtime.Rollback(checkpoint)
baseLibrary.StandardCursor=true
local window,
manager=baseLibrary:CreateWindow{Title="84e Client — integration unavailable",Center=true,AutoShow=true},init.o()
manager:SetLibrary(baseLibrary)
manager:SetFolder"84e Client/NW"
Panels.Build(baseLibrary,window,manager,{InitializationError=modules})
return nil
end

local Core=modules.Core
local Services=Core.Services

local Players,
RunService=Services.Players,Services.RunService
local LocalPlayer=Players.LocalPlayer

Runtime.RegisterValidator("World",function()return Services.Lighting~=nil end)
Runtime.RegisterValidator("Tracer renderer",function()return workspace.CurrentCamera~=nil and Drawing~=nil end)
Runtime.Give(RunService.PreRender:Connect(LPH_JIT_MAX(function(DeltaTime)
if not Runtime.Alive then return end
Runtime.Update("Melee visuals",modules.Features.Combat.MeleeAura.Update)
Runtime.Update("Aim visuals",modules.Features.Combat.SilentAim.Update)
Runtime.Update("Hitbox visuals",modules.Features.Combat.HitboxExtender.Update)
Runtime.Update("Chants",modules.Features.Misc.Chants.Update)
Runtime.Update("Flag state",modules.Features.Misc.FlagMods.Update)
Runtime.Update("Weapon state",modules.Features.Misc.WeaponMods.Update)
Runtime.Update("Movement",modules.Features.Misc.Movement.Update,DeltaTime)
Runtime.Update("World",modules.Features.Visuals.World.Update)
Runtime.Update("Tracer renderer",modules.Features.Visuals.BulletTracers.Update)
end)))

Runtime.Add(function()
local melee=modules.Features.Combat.MeleeAura
melee.Config.Aura=false
local aim=modules.Features.Combat.SilentAim
aim.Config.Enabled=false
modules.Features.Combat.HitboxExtender.Config.Enabled=false
pcall(modules.Features.Combat.HitboxExtender.OnDisable)
modules.Features.Misc.Chants.Config.SpamEnabled=false
modules.Features.Misc.Movement.Config.Fly=false
modules.Features.Misc.Movement.Config.Speed=false
modules.Features.Misc.Movement.Config.ClickTP=false
for _,collection in{melee.RangeLines,melee.TargetLines}do
for key,drawing in collection do
pcall(function()drawing:Remove()end)
collection[key]=nil
end
end
for _,key in{"Line","LineOutline","FOVCircle","FOVCircleOutline","FOVCircleFill"}do
if aim[key]then pcall(function()aim[key]:Remove()end)end
end
end)

Runtime.Give(Players.PlayerAdded:Connect(LPH_JIT_MAX(function(Player)
if Player~=LocalPlayer then
modules.Features.Combat.MeleeAura.CreateLine(Player)
end
end)))

Runtime.Give(Players.PlayerRemoving:Connect(LPH_JIT_MAX(function(Player)
if Player~=LocalPlayer then
local line=modules.Features.Combat.MeleeAura.TargetLines[Player]
if line then Core.Utils.Dispose(line)end
modules.Features.Combat.MeleeAura.TargetLines[Player]=nil
end
end)))

for _,Player in Players:GetPlayers()do
if Player~=LocalPlayer then
modules.Features.Combat.MeleeAura.CreateLine(Player)
end
end

LPH_NO_VIRTUALIZE(function()
local Options,
Toggles,

Library=getgenv().Options,getgenv().Toggles,libs.Library
Runtime.Library=Library

local ThemeManager,
SaveManager,

Window=init.O(),init.o(),Library:CreateWindow{
Title="84e  /  CLIENT",
Size=UDim2.fromOffset(760,640),
Center=true,
AutoShow=true,
TabPadding=4,
MenuFadeTime=0.2,
}

local Tabs={
Legit=Window:AddTab"Legit",
Rage=Window:AddTab"Rage",
Visuals=Window:AddTab"Visuals",
Misc=Window:AddTab"Misc",
Settings=Window:AddTab"Settings",
}

do
local SilentAim,
SilentAimSection=modules.Features.Combat.SilentAim,Tabs.Legit:AddLeftGroupbox"Silent Aim"

SilentAimSection:AddToggle("SilentAimEnabled",{
Text="Enabled",
Default=false,
Callback=function(Value)
SilentAim.Config.Enabled=Value
Options.SilentAimBind:SetNoUI(not Toggles.SilentAimEnabled.Value)
end,
}):AddKeyPicker("SilentAimBind",{
Default="-",
Mode="Toggle",
Text="Silent Aim",
NoUI=true,
SyncToggleState=false,
})

SilentAimSection:AddSlider("SilentAimSmoothing",{
Text="Smoothing",
Default=15,
Min=1,
Max=100,
Suffix="%",
Rounding=0,
Tooltip="Gradually turns the bullet to avoid sharp turns. For more legit shots, lower the value.",
Compact=false,
Callback=function(Value)
SilentAim.Config.Smoothing=Value/100
end,
})

SilentAimSection:AddSlider("SilentAimHitchance",{
Text="HitChance",
Tooltip="One decision per projectile. 0% disables assistance; 100% accepts every eligible projectile. This is assistance probability, not guaranteed hits.",
Default=100,
Min=0,
Max=100,
Suffix="%",
Rounding=0,
Compact=false,
Callback=function(Value)
SilentAim.Config.Hitchance=Value
end,
})

SilentAimSection:AddDropdown("SilentAimAimpart",{
Values={"Head","Torso"},
Multi=false,
Text="Target part",
Default="Head",
Callback=function(Value)
SilentAim.Config.Hitpart=Value
end,
})

SilentAimSection:AddDivider()

SilentAimSection:AddSlider("SilentAimDistanceLimit",{
Text="Max Distance",
Default=500,
Min=0,
Max=2500,
Rounding=0,
Suffix="m",
Compact=false,
Callback=function(Value)
SilentAim.Config.Distance=Value
end,
})

SilentAimSection:AddLabel"Decrease/Increase"
:AddKeyPicker("Decrease",{
Default="",
Text="Decrease Distance",
Mode="Toggle",
NoUI=true,
Callback=function()
Options.SilentAimDistanceLimit:SetValue(Options.SilentAimDistanceLimit.Value-10)
Library:Notify("Max Distance: "..Options.SilentAimDistanceLimit.Value,1)
end,
}):AddKeyPicker("Increase",{
Default="",
Text="Increase Distance",
Mode="Toggle",
NoUI=true,
Callback=function()
Options.SilentAimDistanceLimit:SetValue(Options.SilentAimDistanceLimit.Value+10)
Library:Notify("Max Distance: "..Options.SilentAimDistanceLimit.Value,1)
end,
})

SilentAimSection:AddDivider()

SilentAimSection:AddToggle("SilentAimVisibleCheckEnabled",{
Text="Visible targets only",
Default=false,
Callback=function(Value)
SilentAim.Config.VisibleCheck=Value
end,
})

SilentAimSection:AddToggle("SilentAimPrioritiseFlagBearer",{
Text="Prioritise Flag Bearer",
Default=false,
Callback=function(Value)
SilentAim.Config.FlagBearerPriority=Value
end,
})

Options.Decrease.NoUI=true
Options.Increase.NoUI=true
Options.SilentAimBind.NoUI=true

local OverlayBox=Tabs.Legit:AddTabbox{Side=2}
local FOVSection=OverlayBox:AddTab"FOV"

FOVSection:AddToggle("SilentAimFOVEnabled",{
Text="Enabled",
Default=false,
Callback=function(Value)
SilentAim.FOVConfig.Enabled=Value
end,
})

FOVSection:AddToggle("SilentAimFOVVisible",{
Text="Visible",
Default=false,
Callback=function(Value)
SilentAim.FOVConfig.Visible=Value
end,
}):AddColorPicker("SilentAimFOVColor",{
Title="Color",
Default=Color3.fromRGB(200,50,50),
Transparency=0,
Callback=function(Value)
SilentAim.FOVConfig.Color=Value
end,
})

FOVSection:AddToggle("SilentAimFOVOutline",{
Text="Outline",
Default=false,
Callback=function(Value)
SilentAim.FOVConfig.Outline=Value
end,
})

FOVSection:AddToggle("SilentAimFOVFilled",{
Text="Filled",
Default=false,
Callback=function(Value)
SilentAim.FOVConfig.Filled=Value
end,
}):AddColorPicker("SilentAimFOVFillColor",{
Title="Color",
Default=Color3.fromRGB(200,50,50),
Transparency=0.7,
Callback=function(Value)
SilentAim.FOVFillConfig.Color=Value
end,
})

FOVSection:AddDivider()

FOVSection:AddSlider("SilentAimFOVRadius",{
Text="Radius",
Default=100,
Min=0,
Max=1000,
Rounding=0,
Suffix="px",
Compact=false,
Callback=function(Value)
SilentAim.FOVConfig.Radius=Value
end,
})

FOVSection:AddSlider("SilentAimFOVThickness",{
Text="Thickness",
Default=1,
Min=1,
Max=10,
Rounding=0,
Suffix="px",
Compact=false,
Callback=function(Value)
SilentAim.FOVConfig.Thickness=Value
end,
})

FOVSection:AddSlider("SilentAimFOVNumSides",{
Text="Num Sides",
Default=20,
Min=3,
Max=40,
Rounding=0,
Compact=false,
Callback=function(Value)
SilentAim.FOVConfig.NumSides=Value
end,
})


local LineSection=OverlayBox:AddTab"Target line"

LineSection:AddToggle("SilentAimLineEnabled",{
Text="Enabled",
Default=false,
Callback=function(Value)
SilentAim.LineConfig.Enabled=Value
end,
}):AddColorPicker("SilentAimLineColor",{
Title="Color",
Default=Color3.fromRGB(200,50,50),
Callback=function(Value)
SilentAim.LineConfig.Color=Value
end,
})

LineSection:AddToggle("SilentAimLineOutlineEnabled",{
Text="Outline",
Default=false,
Callback=function(Value)
SilentAim.LineConfig.Outline=Value
end,
})

LineSection:AddSlider("SilentAimLineThickness",{
Text="Thickness",
Default=1,
Min=1,
Max=10,
Rounding=0,
Suffix="px",
Compact=false,
Callback=function(Value)
SilentAim.LineConfig.Thickness=Value
end,
})
end

do
local HitboxExtender,
HitboxExtenderSection=modules.Features.Combat.HitboxExtender,Tabs.Legit:AddRightGroupbox"Hitbox Extender"

local Toggle=HitboxExtenderSection:AddToggle("HitboxExtenderEnabled",{
Text="Enabled",
Default=false,
Callback=function(Value)
HitboxExtender.Config.Enabled=Value

if not Value then
HitboxExtender.OnDisable()
end

Options.HitboxExtenderBind:SetNoUI(not Toggles.HitboxExtenderEnabled.Value)
end,
})

Toggle:AddKeyPicker("HitboxExtenderBind",{
Default="-",
Mode="Toggle",
Text="Hitbox Extender",
NoUI=true,
SyncToggleState=false,
})

Toggle:AddColorPicker("HitboxExtenderColor",{
Title="Color",
Transparency=0,
Default=Color3.fromRGB(255,255,255),
Callback=function(Value)
HitboxExtender.Config.Color=Value
end,
})

Options.HitboxExtenderBind.NoUI=true

HitboxExtenderSection:AddSlider("HitboxExtenderSizeIncrease",{
Text="Size Increase",
Default=1.1,
Min=1.1,
Max=10,
Rounding=1,
Suffix="x",
Compact=false,
Callback=function(Value)
HitboxExtender.Config.SizeIncrease=Value
end
})
end

do
local Melee,
MeleeAuraSection=modules.Features.Combat.MeleeAura,Tabs.Rage:AddLeftGroupbox"Melee Aura"

MeleeAuraSection:AddToggle("MeleeAuraEnabled",{
Text="Enabled (RISKY)",
Default=false,
Risky=true,
Callback=function(Value)
Melee.Config.Aura=Value

if Options.MeleeAuraBind then
Options.MeleeAuraBind:SetNoUI(Toggles.MeleeAuraEnabled and not Toggles.MeleeAuraEnabled.Value or false)
end
end
}):AddKeyPicker("MeleeAuraBind",{
Default="-",
Mode="Toggle",
Text="Melee Aura",
NoUI=true,
SyncToggleState=false,
})

local RangeSlider

MeleeAuraSection:AddToggle("TargetLowHealthPlayers",{
Text="Prioritize Low HP Targets",
Default=false,
Callback=function(Value)
Melee.Config.TargetLowHealth=Value
end,
})

MeleeAuraSection:AddToggle("BypassRangeCheck",{
Text="Bypass Range Check",
Default=false,
Callback=function(Value)
Melee.Config.BypassRangeCheck=Value

if RangeSlider then
if Value then
RangeSlider:SetProperty("Max",20)
else
if RangeSlider.Value>11 then
RangeSlider:SetValue(11)
end

RangeSlider:SetProperty("Max",11)
end
end
end,
})

RangeSlider=MeleeAuraSection:AddSlider("MeleeAuraRange",{
Text="Range",
Default=5,
Min=1,
Max=11,
Rounding=0,
Suffix="m",
Compact=false,
Callback=function(Value)
Melee.Config.AuraRange=Value
end,
})

MeleeAuraSection:AddSlider("MeleeAuraDelay",{
Text="Delay",
Default=0.5,
Min=0.5,
Max=1,
Rounding=2,
Suffix="s",
Compact=false,
Callback=function(Value)
Melee.Config.AuraAttackDelay=Value
end,
})

MeleeAuraSection:AddDivider()

MeleeAuraSection:AddToggle("MeleeAuraCustomDamageEnabled",{
Text="Custom Damage",
Default=false,
Callback=function(Value)
Melee.Config.CustomDamage=Value
end,
})

MeleeAuraSection:AddSlider("MeleeAuraCustomDamage",{
Text="Damage",
Default=50,
Min=1,
Max=50,
Rounding=0,
Suffix="HP",
Compact=false,
Callback=function(Value)
Melee.Config.CustomDamageAmount=Value
end,
})

MeleeAuraSection:AddDivider()

MeleeAuraSection:AddToggle("VisualizeRange",{
Text="Visualize Range",
Default=false,
Callback=function(Value)
Melee.Config.ShowAuraRange=Value
end,
}):AddColorPicker("RangeColor",{
Title="Color",
Default=Color3.fromRGB(255,255,255),
Callback=function(Value)
Melee.Config.ShowAuraRangeColor=Value
end,
})

MeleeAuraSection:AddToggle("VisualizeTargets",{
Text="Visualize Targets",
Default=false,
Callback=function(Value)
Melee.Config.ShowAuraTarget=Value
end,
}):AddColorPicker("LineColor",{
Title="Color",
Default=Color3.fromRGB(255,255,255),
Callback=function(Value)
Melee.Config.ShowAuraTargetColor=Value
end,
})

Options.MeleeAuraBind.NoUI=true
end

do
local World,
WorldSection=init.K(),Tabs.Visuals:AddLeftGroupbox"World"

WorldSection:AddToggle("WorldVisualsEnabled",{
Text="Enabled",
Callback=function(Value)
World.Enabled=Value
end
})

WorldSection:AddDivider()

WorldSection:AddToggle("CustomSkyEnabled",{
Text="Custom Sky",
Callback=function(Value)
World.CustomSkyBox=Value
end,
})

WorldSection:AddDropdown("CustomSkySelected",{
Values={"Default","Stars","Nebula","Winter","Lean","Dark"},
Text="Sky",
Min=1,
Default="Default",
Callback=function(Value)
World.CustomSkyBoxId=Value
end
})

WorldSection:AddDivider()

WorldSection:AddToggle("CustomFogEnabled",{
Text="Custom Fog",
Callback=function(Value)
World.CustomFog=Value
end,
}):AddColorPicker("FogColor",{
Text="Fog Color",
Default=Color3.new(1,1,1),
Callback=function(Value)
World.FogColor=Value
end,
})

WorldSection:AddSlider("FogStart",{
Text="Fog Start",
Default=150,
Min=0,
Max=10000,
Rounding=0,
Compact=false,
Callback=function(Value)
World.FogStart=Value
end,
})

WorldSection:AddSlider("FogEnd",{
Text="Fog End",
Default=10000,
Min=0,
Max=10000,
Rounding=0,
Compact=false,
Callback=function(Value)
World.FogEnd=Value
end,
})
WorldSection:AddDivider()

WorldSection:AddToggle("CustomTimeEnabled",{
Text="Custom Time",
Callback=function(Value)
World.CustomTime=Value
end,
})

WorldSection:AddSlider("CustomTime",{
Text="Time",
Default=12,
Min=0,
Max=24,
Rounding=1,
Suffix=":00",
Compact=false,
Callback=function(Value)
World.CustomTimeNum=Value
end,
})

WorldSection:AddDivider()

WorldSection:AddToggle("CustomAmbienceEnabled",{
Text="Custom Ambience",
Callback=function(Value)
World.CustomAmbience=Value
end,
})

WorldSection:AddLabel"Ambient":AddColorPicker("AmbientColor",{
Text="Ambient",
Default=Color3.new(1,1,1),
Callback=function(Value)
World.Ambient=Value
end,
})

WorldSection:AddLabel"Outdoor Ambient":AddColorPicker("OutdoorAmbientColor",{
Text="Outdoor Ambient",
Default=Color3.new(1,1,1),
Callback=function(Value)
World.OutdoorAmbient=Value
end,
})

WorldSection:AddLabel"Color Shift Top":AddColorPicker("ColorShiftTop",{
Text="Color Shift Top",
Default=Color3.new(1,1,1),
Callback=function(Value)
World.ColorShift_Top=Value
end,
})

WorldSection:AddLabel"Color Shift Bottom":AddColorPicker("ColorShiftBottom",{
Text="Color Shift Bottom",
Default=Color3.new(1,1,1),
Callback=function(Value)
World.ColorShift_Bottom=Value
end,
})
end

do
local Tracers,
BulletTracerSection=init.z(),Tabs.Visuals:AddRightGroupbox"Weapon Visuals"

BulletTracerSection:AddToggle("BulletTracerEnabled",{
Text="Bullet Tracers",
Default=false,
Callback=function(Value)
Tracers.Config.Enabled=Value
end,
}):AddColorPicker("BulletTracerEnabledColor",{
Title="Color",
Default=Color3.fromRGB(255,255,255),
Callback=function(Value)
Tracers.Config.Color=Value
end,
})

BulletTracerSection:AddSlider("BulletTracerEnabledLifeTime",{
Text="Lifetime",
Default=5,
Min=0.1,
Max=10,
Rounding=1,
Suffix="s",
Compact=false,
Callback=function(Value)
Tracers.Config.Duration=Value
end,
})
end

do
local CustomAsset,



Sounds,













GuiSounds,
RequiredGuiSounds,
CombatKillfeedClient,
HitRegSection=function(Path,Link)return Assets.Get("84e Client/assets/"..Path,Link)end,{"discord","mcbow","minecraft","minecraft_xp","neverlose","rust_headshot","skeet","stapler","shooting_star","bubble",},modules.Core.Modules:GetModule"GuiSounds",modules.Core.Modules:GetModule("GuiSounds",true),modules.Core.Modules:GetModule("CombatKillfeedClient",true),Tabs.Visuals:AddRightGroupbox"Hit Registration"

local initialVolume,
initialSound=RequiredGuiSounds.CustomVolume,GuiSounds.Hitmark.SoundId
RequiredGuiSounds.CustomVolume=0.5

HitRegSection:AddDropdown("CustomHitmarker",{
Values=Sounds,
Text="Custom Sound",
Max=1,
Min=0,
AllowNull=true,
Callback=function(Value)
if not Value then
RequiredGuiSounds.CustomSound=false
GuiSounds.Hitmark.SoundId=initialSound
return
end

RequiredGuiSounds.CustomSound=true
local asset,err=CustomAsset("Hitsounds/"..Value..".wav","https://raw.githubusercontent.com/BlackDisciplesHook/Project-X-V3/5b2aef60c716a45b8fd077d4d1701cd533888888/Hitsounds/"..Value..".wav")
if not asset then
RequiredGuiSounds.CustomSound=false
Library:Notify("Sound unavailable: "..tostring(err))
return
end
GuiSounds.Hitmark.SoundId=asset
CombatKillfeedClient.playHitmarkSound()
end
})

HitRegSection:AddSlider("HitmarkerVolume",{
Text="Volume",
Default=50,
Min=1,
Max=100,
Rounding=0,
Suffix="%",
Compact=false,
Callback=function(value)
RequiredGuiSounds.CustomVolume=value/100
end,
})

local Old,
originalSound,
originalVolume=CombatKillfeedClient.playHitmarkSound,initialSound,initialVolume
Runtime.Add(function()
CombatKillfeedClient.playHitmarkSound=Old
GuiSounds.Hitmark.SoundId=originalSound
RequiredGuiSounds.CustomVolume=originalVolume
RequiredGuiSounds.CustomSound=false
end)
CombatKillfeedClient.playHitmarkSound=function()
if not RequiredGuiSounds.CustomSound then
return Old()
end

RequiredGuiSounds.play("Hitmark",1,RequiredGuiSounds.CustomVolume)

return nil
end
end


do
local Chants,
ChantSpamSection,

SelectedChantSet=modules.Features.Misc.Chants,(Tabs.Misc:AddLeftGroupbox"Chant Spam")
local ChantSets=type(Chants.Sets)=="table"and Chants.Sets or{}

ChantSpamSection:AddToggle("ChantSpamEnabled",{
Text="Enabled",
Default=false,
Callback=function(Value)
Chants.Config.SpamEnabled=Value
end
})

ChantSpamSection:AddToggle("ChantSpamEmoteEnabled",{
Text="Emote",
Default=false,
Callback=function(Value)
Chants.Config.EmoteEnabled=Value
end,
})

ChantSpamSection:AddSlider("ChantSpamDelay",{
Text="Delay",
Default=2.5,
Min=1,
Max=10,
Rounding=1,
Suffix="s",
Compact=false,
Callback=function(Value)
Chants.Config.Delay=Value
end,
})

ChantSpamSection:AddDivider()

ChantSpamSection:AddButton{
Text="Chant",
Func=function()
Chants.Chant()
end,
}

ChantSpamSection:AddDropdown("ChantSpamGender",{
Values={"Male","Female","Random"},
Multi=false,
Text="Gender",
Default="Male",
Callback=function(Value)
Chants.Config.SelectedGender=Value
local NewNations={"Random"}

for NationName,NationData in ChantSets do
if Value=="Random"then
if
(NationData.Male and NationData.Male.chants)
or(NationData.Female and NationData.Female.chants)
then
table.insert(NewNations,NationName)
end
else
if NationData[Value]and NationData[Value].chants then
table.insert(NewNations,NationName)
end
end
end

table.sort(NewNations,function(a,b)
if a==b then return false end
if a=="Random"then
return true
end
if b=="Random"then
return false
end
return a<b
end)

if Options.ChantSpamNation then
Options.ChantSpamNation:SetValues(NewNations)
Options.ChantSpamNation:SetValue"Random"
end
end,
})

ChantSpamSection:AddDropdown("ChantSpamNation",{
Values=Chants.Nations,
Multi=false,
Text="Nation",
Default="Italian",
Callback=function(Value)
Chants.Config.SelectedNation=Value
local NationData,

gender=ChantSets[Value],Chants.Config.SelectedGender
if gender=="Random"then gender=NationData and NationData.Male and"Male"or"Female"end
if not NationData or not NationData[gender]or not NationData[gender].chants then
return
end

local ChantGroups,
NewValues=NationData[gender].chants,{"Random"}

for _,group in ChantGroups do
table.insert(NewValues,group.groupname)
end

if SelectedChantSet then
SelectedChantSet:SetValues(NewValues)
SelectedChantSet:SetValue"Random"
end
end
})

SelectedChantSet=ChantSpamSection:AddDropdown("ChantSpamSet",{
Values={"Random","Carica!","Gloria!","Meglio la morte che il disonore!","Vittoria!","Attacco!","Hurrah!","Vive l\'Empereur!"},
Multi=false,
Text="Set",
Default="Carica!",
Callback=function(Value)
Chants.Config.SelectedChantSet=Value
end
})
end

do
local MainMods,
FlagMods,

TabBox=init.F(),init.D(),Tabs.Misc:AddRightTabbox"Mods"

local WeaponMods=TabBox:AddTab'Weapon'

WeaponMods:AddToggle("NoMisfires",{
Text="No Misfires",
Default=false,
Callback=function(Value)
MainMods.Shooting.NoMisfires=Value
end
})

WeaponMods:AddToggle("InstantAim",{
Text="Instant Aim",
Default=false,
Callback=function(Value)
MainMods.Shooting.InstantAim=Value
end,
})

WeaponMods:AddToggle("NoSpread",{
Text="No Spread",
Default=false,
Callback=function(Value)
MainMods.Shooting.NoSpread=Value
end,
})

WeaponMods:AddToggle("NoRecoil",{
Text="No Recoil",
Default=false,
Callback=function(Value)
MainMods.Shooting.NoRecoil=Value
end,
})

WeaponMods:AddToggle("IgnoreReloadPenalties",{
Text="Remove Reload Walking Penalties",
Default=false,
Callback=function(Value)
MainMods.Shooting.IgnoreReloadPenalties=Value
end,
})

WeaponMods:AddDivider()

WeaponMods:AddToggle("CustomDamageForMelee",{
Text="Constant Melee Damage",
Default=false,
Callback=function(Value)
MainMods.Melee.SetDamage=Value
end,
})

WeaponMods:AddSlider("CustomDamageForMeleeAmount",{
Text="Amount",
Default=1,
Min=1,
Max=50,
Rounding=0,
Suffix="HP",
Compact=false,
Callback=function(Value)
MainMods.Melee.SetDamageAmount=Value
end,
})

local FlagModsTab=TabBox:AddTab"Flag"

FlagModsTab:AddToggle("InstantFlagPickup",{
Text="Fast Flag Prompt (RISKY)",
Default=false,
Risky=true,
Callback=function(Value)
FlagMods.Config.InstantCapture=Value
end,
})

FlagModsTab:AddToggle("InstantRespawn",{
Text="Instant Respawn",
Default=false,
Callback=function(Value)
FlagMods.Config.InstantRespawn=Value
end,
})

FlagModsTab:AddToggle("NoSpawnConditions",{
Text="No Spawn Conditions",
Default=false,
Tooltip="Removes all spawn conditions, allowing spawning at any time without restrictions.",
Callback=function(Value)
FlagMods.Config.NoSpawnConditions=Value
end,
})

local MiscMods=TabBox:AddTab"Misc"

MiscMods:AddToggle("InfiniteCavStamina",{
Text="Cavalry Infinite Stamina",
Default=false,
Callback=function(Value)
MainMods.Misc.CavInfStamina=Value
end,
})

MiscMods:AddDivider()

MiscMods:AddToggle("NoMoralLossFromShots",{
Text="No Morale Loss From Shots",
Default=false,
Callback=function(Value)
MainMods.Misc.NoMoralLossFromShots=Value
end,
})

MiscMods:AddToggle("NoMoralLossFromArtillery",{
Text="No Morale Loss From Artillery Fire",
Default=false,
Callback=function(Value)
MainMods.Misc.NoMoralLossFromCannonFire=Value
end,
})

MiscMods:AddToggle("RemoveMoraleCameraShake",{
Text="Remove Morale Based Camera Bob",
Default=false,
Callback=function(Value)
MainMods.Misc.RemoveMoraleCameraShake=Value
end,
})
end

do
local Godmode,
CharacterSection=init.E(),Tabs.Misc:AddRightGroupbox"Character"

CharacterSection:AddToggle("GodmodeEnabled",{
Text="Godmode",
Tooltip="Guide: To make this work, you have to enable the toggle and then die by an external factor, like getting shot by an enemy.",
Callback=function(Value)
if Value then
Godmode.OnEnable()
else
Godmode.OnDisable()
end
end
})

if setfflag then
CharacterSection:AddToggle("FFlagDesyncEnabled",{
Text="FFlag Desync (Freezes Position)",
Callback=function(Value)
Options.FFlagDesyncBind:SetNoUI(not Toggles.FFlagDesyncEnabled.Value)
end
}):AddKeyPicker("FFlagDesyncBind",{
Default="-",
Mode="Toggle",
Text="Desync",
NoUI=true,
SyncToggleState=false,
})

Options.FFlagDesyncBind.NoUI=true

task.spawn(function()
while Runtime.Alive do
setfflag("NextGenReplicatorEnabledWrite4",Options.FFlagDesyncBind:GetState()and"True"or"False")
task.wait(1)
end
end)
end

CharacterSection:AddDivider()

local Movement=init.H()

CharacterSection:AddToggle("FlyEnabled",{
Text="Fly Enabled",
Tooltip="Space to go up, LCTRL to go down.",
Callback=function(Value)
Movement.Config.Fly=Value
Options.FlyBind:SetNoUI(not Toggles.FlyEnabled.Value)
end
}):AddKeyPicker("FlyBind",{
Default="-",
Text="Flight",
NoUI=true,
})

Options.FlyBind.NoUI=true

CharacterSection:AddSlider("FlySpeed",{
Text="Speed",
Default=1,
Min=0.1,
Max=10,
Rounding=1,
Suffix="",
Compact=false,
Callback=function(Value)
Movement.Config.FlySpeed=Value
end,
})

CharacterSection:AddDivider()

CharacterSection:AddToggle("SpeedEnabled",{
Text="Speed Enabled",
Callback=function(Value)
Movement.Config.Speed=Value
Options.SpeedBind:SetNoUI(not Toggles.SpeedEnabled.Value)
end,
}):AddKeyPicker("SpeedBind",{
Default="-",
Text="Speed",
NoUI=true,
})

Options.SpeedBind.NoUI=true

CharacterSection:AddSlider("Speed",{
Text="Speed",
Default=1,
Min=0.1,
Max=10,
Rounding=1,
Suffix="",
Compact=false,
Callback=function(Value)
Movement.Config.SpeedAmount=Value
end,
})

CharacterSection:AddDivider()

CharacterSection:AddToggle("ClickTPEnabled",{
Text="Click Teleport",
Tooltip="Guide: Keybind + MB1 (Left Mouse Button) teleports you to your mouse position!",
Callback=function(Value)
Movement.Config.ClickTP=Value
end,
}):AddKeyPicker("ClickTPBind",{
Default="-",
Mode="Toggle",
Text="Click TP",
NoUI=true,
ChangedCallback=function(New)
Movement.Config.ClickTPBind=New
end
})

Options.ClickTPBind.NoUI=true
end

do
local MenuSection=Tabs.Settings:AddLeftGroupbox"Menu"
MenuSection:AddButton("Stop session",function()Library:Unload()end)
MenuSection:AddButton("Session diagnostics",function()
local failures=0
for _,entry in Runtime.Errors do failures=failures+entry.Count end
Library:Notify("84e "..Preflight.Version.." | error categories: "..tostring(#Runtime.ErrorOrder).." | recorded failures: "..tostring(failures))
end)

MenuSection:AddToggle("Watermark",{
Text="Watermark",
Default=false,
Callback=function(Value)
Library:SetWatermarkVisibility(Value)
end,
})

MenuSection:AddToggle("Keybinds",{
Text="Keybinds",
Default=false,
Callback=function(Value)
Library.KeybindFrame.Visible=Value
end,
})

MenuSection:AddToggle("AllowUnsafeFeatures",{
Text="Allow Risky Features",
Default=false,
Callback=function(Value)
Library.AllowRiskyFeatures=Value
Library:UpdateAllRiskyToggles()
end,
})

MenuSection:AddLabel"Menu bind":AddKeyPicker("MenuKeybind",{
Default="F1",
NoUI=true,
Text="Menu",
})

Library.ToggleKeybind=Options.MenuKeybind
Options.MenuKeybind.NoUI=true

ThemeManager:SetLibrary(Library)
ThemeManager:SetFolder"84e Client/Themes"
ThemeManager:ApplyToTab(Tabs.Settings)

SaveManager:SetLibrary(Library)
SaveManager:SetFolder"84e Client/NW"
SaveManager:IgnoreThemeSettings()
SaveManager:BuildConfigSection(Tabs.Settings)
local world=modules.Features.Visuals.World
Panels.Build(Library,Window,SaveManager,{
World=world,Tracers=modules.Features.Visuals.BulletTracers,ThemeManager=ThemeManager,
SyncWorld=function()
SaveManager.Loading=true
local values={WorldVisualsEnabled=world.Enabled,CustomSkyEnabled=world.CustomSkyBox,
CustomFogEnabled=world.CustomFog,CustomTimeEnabled=world.CustomTime,
CustomAmbienceEnabled=world.CustomAmbience,App_ClearAtmosphere=world.ClearAtmosphere}
for key,value in values do if Toggles[key]then Toggles[key]:SetValue(value)end end
local values2={CustomSkySelected=world.CustomSkyBoxId,FogStart=world.FogStart,FogEnd=world.FogEnd,
CustomTime=world.CustomTimeNum}
for key,value in values2 do if Options[key]then Options[key]:SetValue(value)end end
for key,value in{FogColor=world.FogColor,AmbientColor=world.Ambient,OutdoorAmbientColor=world.OutdoorAmbient,
ColorShiftTop=world.ColorShift_Top,ColorShiftBottom=world.ColorShift_Bottom}do
if Options[key]then Options[key]:SetValueRGB(value)end
end
SaveManager.Loading=false
end,
})
local valid,initial=SaveManager:Validate(SaveManager:Capture())
if valid then
SaveManager.Loading=true
for _,entry in initial do
Library:SafeCallback(SaveManager.Parser[entry.type].Load,entry.idx,entry)
end
SaveManager.Loading=false
end
SaveManager:LoadAutoloadConfig()

Library:SetWatermark("84e Client - "
..os.date"%b %d %Y"
.." - "
..(function()
local ok,product=pcall(function()return game:GetService"MarketplaceService":GetProductInfoAsync(game.PlaceId)end)
return ok and product.Name or tostring(game.PlaceId)
end)()
)

Library:SetWatermarkVisibility(Toggles.Watermark.Value)
end
end)()

return nil end function init.P()local v=init.cache.P if not v then v={c=__modImpl()}init.cache.P=v end return v.c end end end


if not LPH_OBFUSCATED then
local assert,
type,
setfenv=assert,type,setfenv

LPH_ENCNUM=function(toEncrypt,...)
assert(
type(toEncrypt)=="number"and#{...}==0,
"LPH_ENCNUM only accepts a single constant double or integer as an argument."
)
return toEncrypt
end

LPH_NUMENC=LPH_ENCNUM

LPH_ENCSTR=function(toEncrypt,...)
assert(
type(toEncrypt)=="string"and#{...}==0,
"LPH_ENCSTR only accepts a single constant string as an argument."
)
return toEncrypt
end

LPH_STRENC=LPH_ENCSTR

LPH_ENCFUNC=function(toEncrypt,encKey,decKey,...)

assert(
type(toEncrypt)=="function"and type(encKey)=="string"and#{...}==0,
"LPH_ENCFUNC accepts a constant function, constant string, and string variable as arguments."
)
return toEncrypt
end

LPH_FUNCENC=LPH_ENCFUNC

LPH_JIT=function(f,...)
assert(
type(f)=="function"and#{...}==0,
"LPH_JIT only accepts a single constant function as an argument."
)
return f
end

LPH_JIT_MAX=LPH_JIT

LPH_NO_VIRTUALIZE=function(f,...)
assert(
type(f)=="function"and#{...}==0,
"LPH_NO_VIRTUALIZE only accepts a single constant function as an argument."
)
return f
end

LPH_NO_UPVALUES=function(f,...)
assert(type(setfenv)=="function","LPH_NO_UPVALUES can only be used on Lua versions with getfenv & setfenv")
assert(
type(f)=="function"and#{...}==0,
"LPH_NO_UPVALUES only accepts a single constant function as an argument."
)
return f
end

LPH_CRASH=function(...)
assert(#{...}==0,"LPH_CRASH does not accept any arguments.")
end

LRM_INIT_SCRIPT=function(f,...)
assert(
type(f)=="function"and#{...}==0,
"LRM_INIT_SCRIPT only accepts a single constant function as an argument."
)
return f
end

LRM_SEND_WEBHOOK=function(url,template)
assert(
type(url)=="string"and type(template)=="table",
"LRM_SEND_WEBHOOK only accepts a url constant and a webhook template as arguments."
)
end

LRM_SANITIZE=function(...)
return""
end
end

if game.GameId==4260784961 and game.PlaceId~=12068120918 then
local initialized,initError=pcall(function()init.P()end)
if not initialized then
local session=getgenv().Client84eSession
if session and session.Stop then pcall(session.Stop)end
warn("84e initialization failed: "..tostring(initError))
end
end