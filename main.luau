local init={cache={}}do do local __modImpl=function()local Scope={}
Scope.__index=Scope

function Scope.new(name)
return setmetatable({Name=name or"scope",Alive=true,Items={},Order={},Errors={},Generation=0},Scope)
end local dispose=function(

value, cleanup)
if cleanup then return cleanup(value)end
if type(value)=="function"then return value()end
local kind=typeof(value)
if kind=="Instance"then return value:Destroy()end
if kind=="RBXScriptConnection"then return value:Disconnect()end
for _,name in{"Disconnect","Destroy","Remove"}do
local ok,method=pcall(function()return value[name]end)
if ok and type(method)=="function"then return method(value)end
end
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
return{Version="V2.7",Alive=Runtime.Alive,ResourceCount=Runtime.Resources:Count(),
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

return init.e()end function init.f()local v=init.cache.f if not v then v={c=__modImpl()}init.cache.f=v end return v.c end end do local __modImpl=function()local Preflight={Version="V2.7",Snapshot="Barraux 2266 / 2026-08-15"}

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
Hue={Registry={},RegistryMap={},HudRegistry={},FontColor=Color3.fromRGB(230,234,245),DisabledColor=Color3.fromRGB(65,65,65),MainColor=Color3.fromRGB(23,27,37),BackgroundColor=Color3.fromRGB(14,17,24),AccentColor=Color3.fromRGB(124,140,255),OutlineColor=Color3.fromRGB(43,50,67),RiskColor=Color3.fromRGB(200,50,50),Black=Color3.new(0,0,0),FontFace=Font.fromEnum(Enum.Font.BuilderSans),Font=Enum.Font.BuilderSans,AllowRiskyFeatures=false,OpenedFrames={},DependencyBoxes={},Signals={},UnloadCallbacks={},Alive=true,NotifyOnError=true,SaveQueued=false,FontScale=1,ReducedMotion=false,StandardCursor=false,MenuVisible=false,FontBaselines=setmetatable({},{__mode="k"}),ScreenGui=ScreenGui,},0,0

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
local function resizeTabs(tabs)
for _,tab in tabs do
for _,group in tab.Groupboxes do group:Resize()end
for _,box in tab.Tabboxes do
for _,page in box.Tabs do if page.Resize then page:Resize()end end
end
resizeTabs(tab.Pages)
end
end
resizeTabs(Library.Window.Tabs)
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

function Library.Round(self,frame,radius,outline)
frame.BorderSizePixel=0
local corner=Library:Create("UICorner",{CornerRadius=UDim.new(0,radius),Parent=frame})
if outline then
local stroke=Library:Create("UIStroke",{Color=Library.OutlineColor,Thickness=1,Parent=frame})
Library:AddToRegistry(stroke,{Color="OutlineColor"})
end
return corner
end

function Library.SetUIScale(self,value)
assert(type(value)=="number"and value==value and math.abs(value)<math.huge,"invalid UI scale")
self.RequestedUIScale=math.clamp(value,0.75,1.5)
if self.Window and self.Window.FitToViewport then self.Window:FitToViewport()end
end

function Library.CreateLabel(self,Properties,IsHud)
local _Instance=Library:Create("TextLabel",{
BackgroundTransparency=1,
Font=Library.Font,
FontFace=Library.FontFace,
TextColor3=Library.FontColor,
TextSize=13,
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
local X,Y=Library:GetTextBounds(InfoStr,Library.FontFace,13)
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
TextSize=13,
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
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
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
TextSize=13,
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











ContextMenu=Library:CreateLabel{Size=UDim2.new(1,0,0,14),Position=UDim2.fromOffset(5,5),TextXAlignment=Enum.TextXAlignment.Left,TextSize=13,Text=ColorPicker.Title,TextWrapped=false,ZIndex=16,Parent=PickerFrameInner,FontFace=Library.FontFace,}, {}

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
TextSize=13,
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
Library:Round(PickOuter,5)

local PickInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=7,
Parent=PickOuter,
})

Library:Round(PickInner,5)
Library:AddToRegistry(PickInner,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

local DisplayLabel,








ModeSelectOuter=Library:CreateLabel{Size=UDim2.new(1,0,1,0),TextSize=13,Text=Info.Default,TextWrapped=true,ZIndex=8,Parent=PickInner,},Library:Create("Frame",{
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
ModeButtons=Library:CreateLabel({TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,18),TextSize=13,Visible=false,ZIndex=110,Parent=Library.KeybindContainer,},true),Info.Modes or{"Always","Toggle","Hold"},{}

for Idx,Mode in next,Modes do
local ModeButton,

Label={},Library:CreateLabel{
Active=false,
Size=UDim2.new(1,0,0,15),
TextSize=13,
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
TextSize=13,
Text=Text,
TextWrapped=DoesWrap or false,
TextXAlignment=Enum.TextXAlignment.Left,
ZIndex=5,
Parent=Container,
}

if DoesWrap then
local Y=select(
2,
Library:GetTextBounds(Text,Library.FontFace,13,Vector2.new(TextLabel.AbsoluteSize.X,math.huge))
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
Library:GetTextBounds(Text,Library.FontFace,13,Vector2.new(TextLabel.AbsoluteSize.X,math.huge))
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
Size=UDim2.new(1,-4,0,26),
ZIndex=5,
})

Library:Round(Outer,5)
local Inner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=6,
Parent=Outer,
})local

Gradient, 








Label=Library:Create("UIGradient",{Rotation=90,Parent=Inner,Color=ColorSequence.new{ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),},}), Library:CreateLabel{
Size=UDim2.new(1,0,1,0),
TextSize=13,
Text=Button.Text,
ZIndex=6,
Parent=Inner,
}

Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
},
Rotation=90,
Parent=Inner,
})

Library:AddToRegistry(Outer,{
BorderColor3="Black",
})

Library:Round(Inner,5,true)
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
TextSize=13,
Text=Info.Text,
TextXAlignment=Enum.TextXAlignment.Left,
ZIndex=5,
Parent=Container,
}

Groupbox:AddBlank(1)

local TextBoxOuter=Library:Create("Frame",{
BackgroundColor3=Color3.new(0,0,0),
BorderColor3=Color3.new(0,0,0),
Size=UDim2.new(1,-4,0,26),
ZIndex=5,
Parent=Container,
})
Library:Round(TextBoxOuter,5)

local TextBoxInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,1,0),
ZIndex=6,
Parent=TextBoxOuter,
})

Library:Round(TextBoxInner,5)
Library:AddToRegistry(TextBoxInner,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

Library:OnHighlight(TextBoxOuter,TextBoxOuter,{BorderColor3="AccentColor"},{BorderColor3="Black"})

if type(Info.Tooltip)=="string"then
Library:AddToolTip(Info.Tooltip,TextBoxOuter)
end

Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
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
TextSize=13,
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
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
},
})

Library:AddToRegistry(ToggleInner,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

local ToggleLabel=Library:CreateLabel{
Size=UDim2.new(0,216,1,0),
Position=UDim2.new(1,6,0,0),
TextSize=13,
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
Size=UDim2.new(1,0,0,16),
TextSize=13,
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
Size=UDim2.new(1,-4,0,18),
ZIndex=5,
Parent=Container,
})
Library:Round(SliderOuter,5)

Library:AddToRegistry(SliderOuter,{
BorderColor3="Black",
})

local SliderInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
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
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
},
})

Library:Round(SliderInner,5)
Library:AddToRegistry(SliderInner,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

local Fill=Library:Create("Frame",{
BackgroundColor3=Library.AccentColor,
BorderSizePixel=0,
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
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
},
})

Library:Round(Fill,5)
Library:AddToRegistry(Fill,{
BackgroundColor3="AccentColor",
BorderColor3="AccentColorDark",
})

local DisplayLabel=Library:CreateLabel{
Size=UDim2.new(1,0,1,0),
TextSize=13,
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
Size=UDim2.new(1,0,0,16),
TextSize=13,
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
Size=UDim2.new(1,-4,0,26),
ZIndex=5,
Parent=Container,
})
Library:Round(DropdownOuter,5)

Library:AddToRegistry(DropdownOuter,{
BorderColor3="Black",
})

local DropdownInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
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
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
},
})

Library:Round(DropdownInner,5)
Library:AddToRegistry(DropdownInner,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

Library:Create("UIGradient",{
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
},
Rotation=90,
Parent=DropdownInner,
})

local DropdownArrow,









ItemList=Library:Create("ImageLabel",{AnchorPoint=Vector2.new(0,0.5),BackgroundTransparency=1,Position=UDim2.new(1,-16,0.5,0),Size=UDim2.new(0,12,0,12),Image="http://www.roblox.com/asset/?id=6282522798",ZIndex=8,Parent=DropdownInner,}),Library:CreateLabel{
Position=UDim2.new(0,5,0,0),
Size=UDim2.new(1,-5,1,0),
TextSize=13,
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
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
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
TextSize=13,
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
TextSize=13,
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
local X,Y=Library:GetTextBounds(Text,Library.FontFace,13)
Library.Watermark.Size=UDim2.new(0,X+15,0,(Y*1.5)+3)
Library:SetWatermarkVisibility(true)

Library.WatermarkText.Text=Text
end

function Library.Notify(self,Text,Time)
if not Library.Alive then return end
Text=tostring(Text)
local XSize,YSize=Library:GetTextBounds(Text,Library.FontFace,13)

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









LeftColor=Library:CreateLabel{Position=UDim2.new(0,4,0,0),Size=UDim2.new(1,-4,1,0),Text=Text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=13,ZIndex=103,Parent=InnerFrame,}, Library:Create("Frame",{
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
Config.Size=UDim2.fromOffset(920,660)
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

Library:MakeDraggable(Outer,58)
Library:Round(Outer,12)
Library.ScaleControl=Library:Create("UIScale",{Scale=1,Parent=Outer})
Window.Outer=Outer
local scaleControl,
viewportConnection=(Library.ScaleControl)
function Window.FitToViewport(self)
local scale,
camera=Library.RequestedUIScale or 1,workspace.CurrentCamera
if camera then
local view=camera.ViewportSize
if view and view.X>0 and view.Y>0 then
scale=math.min(scale,math.max(0.1,(view.X-32)/Config.Size.X.Offset),math.max(0.1,(view.Y-32)/Config.Size.Y.Offset))
end
end
scaleControl.Scale=scale
end local watchCamera=function()

if viewportConnection then Runtime.Release(viewportConnection,true)viewportConnection=nil end
local camera=workspace.CurrentCamera
if camera then
viewportConnection=Runtime.Own(camera:GetPropertyChangedSignal"ViewportSize":Connect(function()Window:FitToViewport()end))
end
Window:FitToViewport()end

if workspace.GetPropertyChangedSignal then
Runtime.Own(workspace:GetPropertyChangedSignal"CurrentCamera":Connect(watchCamera))
end
watchCamera()

local Glow=Library:Create("ImageLabel",{
Parent=Outer,
ImageColor3=Library.AccentColor,
ScaleType=Enum.ScaleType.Slice,
BorderColor3=Color3.fromRGB(0,0,0),
BackgroundColor3=Color3.fromRGB(255,255,255),
Image="http://www.roblox.com/asset/?id=18245826428",
BackgroundTransparency=1,
ImageTransparency=0.97,
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

Library:Round(Inner,12,true)
Library:AddToRegistry(Inner,{
BackgroundColor3="MainColor",
BorderColor3="AccentColor",
})

local WindowLabel,










MainSectionOuter=Library:CreateLabel{Position=UDim2.new(0,24,0,10),TextSize=24,FontFace=Font.fromEnum(Enum.Font.BuilderSansBold),Size=UDim2.new(0,140,0,32),Text=Config.Title or"",TextXAlignment=Enum.TextXAlignment.Left,ZIndex=1,Parent=Inner,},Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
Position=UDim2.new(0,12,0,58),
Size=UDim2.new(1,-24,1,-70),
BorderSizePixel=0,
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

Library:CreateLabel{Text=Config.Subtitle or"V2.7",TextSize=11,
TextXAlignment=Enum.TextXAlignment.Right,Position=UDim2.new(1,-280,0,19),
Size=UDim2.fromOffset(250,18),Parent=Inner,ZIndex=2}
local SectionTitle,


SectionDescription,


descriptions=Library:CreateLabel{Text="",TextSize=22,FontFace=Font.fromEnum(Enum.Font.BuilderSansBold),TextXAlignment=Enum.TextXAlignment.Left,Position=UDim2.new(0,186,0,12),Size=UDim2.new(1,-202,0,30),Parent=MainSectionInner,ZIndex=3},Library:CreateLabel{Text="",TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Position=UDim2.new(0,186,0,44),Size=UDim2.new(1,-202,0,20),Parent=MainSectionInner,ZIndex=3},{Legit="Precision and targeting",Rage="Melee and combat",Visuals="World and weapon presentation",
Misc="Movement and character",Settings="Preferences, profiles and session health"}
Library:CreateLabel{Text="WORKSPACE",TextSize=10,TextXAlignment=Enum.TextXAlignment.Left,
Position=UDim2.fromOffset(16,16),Size=UDim2.fromOffset(148,18),Parent=MainSectionInner,ZIndex=3}

local TabArea=Library:Create("Frame",{
BackgroundTransparency=1,
Position=UDim2.new(0,12,0,46),
Size=UDim2.new(0,152,1,-108),
ZIndex=1,
Parent=MainSectionInner,
})

local TabListLayout,






TabContainer=Library:Create("UIListLayout",{Padding=UDim.new(0,8),FillDirection=Enum.FillDirection.Vertical,SortOrder=Enum.SortOrder.LayoutOrder,Parent=TabArea,}),Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
Position=UDim2.new(0,178,0,78),
Size=UDim2.new(1,-190,1,-90),
BackgroundTransparency=1,
BorderSizePixel=0,
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

function Window.AddTab(self,Name,Owner)local
TabArea, 
TabContainer, 
TabListLayout, 
siblings, 
Tab, 





TabButtonWidth=Owner and Owner.PageNav or TabArea, Owner and Owner.PageContainer or TabContainer, Owner and Owner.PageLayout or TabListLayout, Owner and Owner.Pages or Window.Tabs, {Name=Name,ParentTab=Owner,Pages={},Groupboxes={},Tabboxes={},}, Library:GetTextBounds(Name,Library.FontFace,16)

local TabButton=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Library.OutlineColor,
Size=Owner and UDim2.new(0,12,1,0)or UDim2.new(1,0,0,42),
BorderSizePixel=0,
ZIndex=1,
Parent=TabArea,
})

Library:Create("UIGradient",{
Rotation=-90,
Parent=TabButton,
Color=ColorSequence.new{
ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),
ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),
},
})

Library:AddToRegistry(TabButton,{
BackgroundColor3="BackgroundColor",
BorderColor3="OutlineColor",
})

Library:Round(TabButton,7)local
TabButtonLabel, 










Blocker=Library:CreateLabel{Position=UDim2.new(0,0,0,0),Size=UDim2.new(1,-24,1,-1),Position=UDim2.fromOffset(12,0),TextXAlignment=Owner and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left,TextSize=14,Text=Name,ZIndex=1,Parent=TabButton,}, Library:Create("Frame",{
BackgroundColor3=Library.AccentColor,
BorderSizePixel=0,
Position=Owner and UDim2.new(0,8,1,-2)or UDim2.new(0,0,0,10),
Size=Owner and UDim2.new(1,-16,0,2)or UDim2.new(0,3,1,-20),
BackgroundTransparency=1,
ZIndex=3,
Parent=TabButton,
})

Library:AddToRegistry(Blocker,{
BackgroundColor3="AccentColor",
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













RightSide=Library:Create("UIGradient",{Rotation=-90,Parent=TabFrame,Color=ColorSequence.new{ColorSequenceKeypoint.new(0,Color3.fromRGB(255,255,255)),ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255)),},}), Library:Create("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,7,0,7),Size=UDim2.new(0.5,-10,1,-14),CanvasSize=UDim2.new(0,0,0,0),BottomImage="",TopImage="",ScrollBarThickness=3,ScrollBarImageColor3=Library.OutlineColor,ZIndex=2,Parent=TabFrame,}), Library:Create("ScrollingFrame",{
BackgroundTransparency=1,
BorderSizePixel=0,
Position=UDim2.new(0.5,5,0,7),
Size=UDim2.new(0.5,-10,1,-14),
CanvasSize=UDim2.new(0,0,0,0),
BottomImage="",
TopImage="",
ScrollBarThickness=3,
ScrollBarImageColor3=Library.OutlineColor,
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

Tab.Frame=TabFrame
Tab.Button=TabButton
function Tab.ReflowColumns(self)
local hasRight=false
for _,child in RightSide:GetChildren()do if child:IsA"Frame"then hasRight=true break end end
LeftSide.Size=hasRight and UDim2.new(0.5,-10,1,-14)or UDim2.new(1,-14,1,-14)
RightSide.Visible=hasRight
end
function Tab.AddPage(self,PageName)
if not self.PageNav then
LeftSide.Visible=false RightSide.Visible=false
self.PageNav=Library:Create("Frame",{BackgroundTransparency=1,
Position=UDim2.fromOffset(7,0),Size=UDim2.new(1,-14,0,34),Parent=TabFrame,ZIndex=3})
self.PageLayout=Library:Create("UIListLayout",{Padding=UDim.new(0,8),FillDirection=Enum.FillDirection.Horizontal,
HorizontalFlex=Enum.UIFlexAlignment.Fill,SortOrder=Enum.SortOrder.LayoutOrder,Parent=self.PageNav})
self.PageContainer=Library:Create("Frame",{BackgroundTransparency=1,
Position=UDim2.fromOffset(0,46),Size=UDim2.new(1,0,1,-46),Parent=TabFrame,ZIndex=2})
end
return Window:AddTab(PageName,self)
end
function Tab.ShowTab(self,SkipParent)
if Owner and not SkipParent then Owner:ShowTab()end
for _,Tab in next,siblings do
Tab:HideTab()
end

Blocker.BackgroundTransparency=0
TabButton.BackgroundColor3=Library.MainColor
Library.RegistryMap[TabButton].Properties.BackgroundColor3="MainColor"
TabFrame.Visible=true
Tab.Visible=true
if Owner then
Owner.CurrentPage=Tab
if Owner.Visible then if Owner.Visible then SectionTitle.Text=Owner.Name.." / "..Name end end
else
SectionTitle.Text=Name
SectionDescription.Text=descriptions[Name]or"Client preferences"
if Tab.CurrentPage then SectionTitle.Text=Name.." / "..Tab.CurrentPage.Name end
end
end

function Tab.HideTab(self)
Library:ClosePopups()
Blocker.BackgroundTransparency=1
TabButton.BackgroundColor3=Library.BackgroundColor
Library.RegistryMap[TabButton].Properties.BackgroundColor3="BackgroundColor"
TabFrame.Visible=false
Tab.Visible=false
end

function Tab.SetLayoutOrder(self,Position)
TabButton.LayoutOrder=Position
TabListLayout:ApplyLayout()
end

function Tab.AddGroupbox(self,Info)
local Groupbox,

BoxOuter={Name=Info.Name,OwnerTab=Tab},Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Library.OutlineColor,
BorderMode=Enum.BorderMode.Inset,
Size=UDim2.new(1,0,0,509),
ZIndex=2,
Parent=Info.Side==1 and LeftSide or RightSide,
})

Library:AddToRegistry(BoxOuter,{
BackgroundColor3="MainColor",
BorderColor3="OutlineColor",
})

Library:Round(BoxOuter,8)
local BoxInner=Library:Create("Frame",{
BackgroundColor3=Library.MainColor,
BorderColor3=Color3.new(0,0,0),

Size=UDim2.new(1,-2,1,-2),
Position=UDim2.new(0,1,0,1),
ZIndex=4,
Parent=BoxOuter,
})

Library:Round(BoxInner,8,true)
Library:AddToRegistry(BoxInner,{
BackgroundColor3="MainColor",
})

local Highlight=Library:Create("Frame",{
Visible=false,
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










Container=Library:CreateLabel{Size=UDim2.new(1,-24,0,24),Position=UDim2.new(0,12,0,4),FontFace=Font.fromEnum(Enum.Font.BuilderSansMedium),TextSize=14,Text=Info.Name,TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,Parent=BoxInner,}, Library:Create("Frame",{
BackgroundTransparency=1,
Position=UDim2.new(0,12,0,32),
Size=UDim2.new(1,-24,1,-32),
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

BoxOuter.Size=UDim2.new(1,0,0,32+Size+12)
end

Groupbox.Container=Container
setmetatable(Groupbox,BaseGroupbox)

Groupbox:AddBlank(3)
Groupbox:Resize()

Tab:ReflowColumns()
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

Library:Round(BoxOuter,8)
local BoxInner=Library:Create("Frame",{
BackgroundColor3=Library.BackgroundColor,
BorderColor3=Color3.new(0,0,0),

Size=UDim2.new(1,-2,1,-2),
Position=UDim2.new(0,1,0,1),
ZIndex=4,
Parent=BoxOuter,
})

Library:Round(BoxInner,8,true)
Library:AddToRegistry(BoxInner,{
BackgroundColor3="BackgroundColor",
})

local Highlight=Library:Create("Frame",{
Visible=false,
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
Position=UDim2.new(0,8,0,4),
Size=UDim2.new(1,-16,0,28),
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








Block=Library:CreateLabel{Size=UDim2.new(1,0,1,0),TextSize=13,Text=Name,TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7,Parent=Button,}, Library:Create("Frame",{
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
Position=UDim2.new(0,12,0,36),
Size=UDim2.new(1,-24,1,-36),
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

BoxOuter.Size=UDim2.new(1,0,0,36+Size+12)
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

Tab:ReflowColumns()
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


if next(siblings)==nil then
Tab:ShowTab(true)
end

siblings[Name]=Tab
Tab:ReflowColumns()
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

local FadeTime=Library.ReducedMotion and 0 or Config.MenuFadeTime

Fading=true

Toggled=not Toggled
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

for _,Prop in next,Properties do local __DARKLUA_CONTINUE_83=false repeat
if not Cache[Prop]then
Cache[Prop]=Desc[Prop]
end

if Cache[Prop]==1 then __DARKLUA_CONTINUE_83=true
break
end

TweenService:Create(
Desc,
TweenInfo.new(FadeTime,Enum.EasingStyle.Linear),
{[Prop]=Toggled and Cache[Prop]or 1}
):Play()__DARKLUA_CONTINUE_83=true until true if not __DARKLUA_CONTINUE_83 then break end
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
local Storage,
Assets,le,





samples=init.c(),init.f(),function(value, count)local bytes={}for index=1,count do bytes[index]=string.char(value%256)value=math.floor(value/256)end return table.concat(bytes)end,{}
for index=0,319 do
local envelope=(1-index/320)^3
samples[index+1]=string.char(math.clamp(math.floor(128+30*envelope*math.sin(index*math.pi*2*1200/8000)),0,255))
end
local pcm=table.concat(samples)
local wav,

path,
made,err="RIFF"..le(36+#pcm,4).."WAVEfmt "..le(16,4)..le(1,2)..le(1,2)..le(8000,4)..le(8000,4)..le(1,2)..le(8,2).."data"..le(#pcm,4)..pcm,"84e Client/assets/ui_click.wav",Storage.MakeFolders"84e Client/assets"
if not made then return false,err end
local saved saved,err=Storage.Write(path,wav)
if not saved then return false,err end
Assets.Invalidate(path,false)
local asset asset,err=Assets.GetLocal(path)
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
return Audio end function init.k()local v=init.cache.k if not v then v={c=__modImpl()}init.cache.k=v end return v.c end end do local __modImpl=function()

local Runtime,
Storage,
Preflight,
Navigation,
Audio,
HttpService,
Panels=init.b(),init.c(),init.g(),init.h(),init.k(),game:GetService"HttpService",{}

function Panels.Build(library,window,manager,context)
context=context or{}
local options,
pages=getgenv().Options,context.SettingsPages
if not pages then
local settings=window.Tabs.Settings or window:AddTab"Settings"
settings:SetLayoutOrder(5)
pages={General=settings:AddPage"General",Appearance=settings:AddPage"Appearance",
Profiles=settings:AddPage"Profiles",Diagnostics=settings:AddPage"Diagnostics"}
end
local tools,diagnostics,report=pages.General,pages.Diagnostics,function(
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

local access=pages.Appearance:AddRightGroupbox"Accessibility"
access:AddSlider("App_UIScale",{Text="UI scale",Default=1,Min=0.75,Max=1.5,Rounding=2,Callback=function(value)
library:SetUIScale(value)
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

local profiles=pages.Profiles:AddLeftGroupbox"Profile management"
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
visual=context.World,pages.Appearance:AddLeftGroupbox"Visual ownership and preview"
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

local budget=pages.General:AddRightGroupbox"Visual and audio budgets"
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

return Panels end function init.l()local v=init.cache.l if not v then v={c=__modImpl()}init.cache.l=v end return v.c end end do local __modImpl=function()


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
for _,entry in data.objects do local __DARKLUA_CONTINUE_103=false repeat
if type(entry)~="table"or type(entry.idx)~="string"or type(entry.type)~="string"then
return false,"invalid profile entry"
end
if seen[entry.idx]then return false,"duplicate setting: "..entry.idx end
seen[entry.idx]=true
local object=entry.type=="Toggle"and Toggles[entry.idx]or Options[entry.idx]
if not object or self.Ignore[entry.idx]then __DARKLUA_CONTINUE_103=true break end
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
table.insert(entries,value)__DARKLUA_CONTINUE_103=true until true if not __DARKLUA_CONTINUE_103 then break end
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
return SaveManager end function init.m()local v=init.cache.m if not v then v={c=__modImpl()}init.cache.m=v end return v.c end end do local __modImpl=function()

local Services={}

for _,Service in{"Players","RunService","UserInputService","CoreGui","Debris","ReplicatedStorage","Lighting","HttpService","PathfindingService"}do
Services[Service]=cloneref(game:GetService(Service))
end

return Services end function init.n()local v=init.cache.n if not v then v={c=__modImpl()}init.cache.n=v end return v.c end end do local __modImpl=function()

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

for Index=1,#Modules.GarbageCollection do local __DARKLUA_CONTINUE_114=false repeat
local Value=Modules.GarbageCollection[Index]

if not Value or typeof(Value)~="function"then __DARKLUA_CONTINUE_114=true
break
end

local source=debug.info(Value,"s")
if not source or not string_find(source,Name,1,true)then __DARKLUA_CONTINUE_114=true
break
end

local env=getfenv(Value)
if typeof(env)~="table"then __DARKLUA_CONTINUE_114=true
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
end __DARKLUA_CONTINUE_114=true until true if not __DARKLUA_CONTINUE_114 then break end
end

return nil
end

return Modules end function init.o()local v=init.cache.o if not v then v={c=__modImpl()}init.cache.o=v end return v.c end end do local __modImpl=function()

local Variables,




GarbageCollection={Cache={},Captured={},},getgc(true)

Variables.VariablesIndex=(LPH_JIT_MAX(function()
for i=1,#GarbageCollection do local __DARKLUA_CONTINUE_115=false repeat
local Value=GarbageCollection[i]

if typeof(Value)~="function"then __DARKLUA_CONTINUE_115=true
break
end

local info=debug.getinfo(Value)

if not info or not string.match(info.source,"ReplicatedStorage.Variables")then __DARKLUA_CONTINUE_115=true
break
end

if info.name=="index"then __DARKLUA_CONTINUE_115=true
break
end

return Value until true if not __DARKLUA_CONTINUE_115 then break end
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
return Variables end function init.p()local v=init.cache.p if not v then v={c=__modImpl()}init.cache.p=v end return v.c end end do local __modImpl=function()
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

return Utils end function init.q()local v=init.cache.q if not v then v={c=__modImpl()}init.cache.q=v end return v.c end end do local __modImpl=function()

return init.q()end function init.r()local v=init.cache.r if not v then v={c=__modImpl()}init.cache.r=v end return v.c end end do local __modImpl=function()






















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
}end function init.s()local v=init.cache.s if not v then v={c=__modImpl()}init.cache.s=v end return v.c end end do local __modImpl=function()
return{
Services=init.n(),
Modules=init.o(),
Variables=init.p(),
Utils=init.r(),
Hashes=init.s()
}end function init.t()local v=init.cache.t if not v then v={c=__modImpl()}init.cache.t=v end return v.c end end do local __modImpl=function()

local Networking,




Core={Debounces={},Blacklist={"SelfReport"},},init.t()
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

for _,v in upvalue do local __DARKLUA_CONTINUE_121=false repeat
if typeof(v)~="function"then __DARKLUA_CONTINUE_121=true
break
end

if debug.info(v,"n")~="FireServer"then __DARKLUA_CONTINUE_121=true
break
end

return v until true if not __DARKLUA_CONTINUE_121 then break end
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

return Networking end function init.u()local v=init.cache.u if not v then v={c=__modImpl()}init.cache.u=v end return v.c end end do local __modImpl=function()

return init.u()end function init.v()local v=init.cache.v if not v then v={c=__modImpl()}init.cache.v=v end return v.c end end do local __modImpl=function()local HitboxExtender,










Core={Config={Enabled=false,SizeIncrease=2,Transparency=0,Material=Enum.Material.ForceField,Color=Color3.fromRGB(255,255,255),},},init.t()
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

for i=1,#Players do local __DARKLUA_CONTINUE_124=false repeat
local Player=Players[i]

if Player==LocalPlayer then __DARKLUA_CONTINUE_124=true
break
end

if not Player.Character then __DARKLUA_CONTINUE_124=true
break
end

local Character=Player.Character
local HumanoidRootPart=Character and Character:FindFirstChild"HumanoidRootPart"

if not HumanoidRootPart then __DARKLUA_CONTINUE_124=true
break
end

if Player.Team==LocalPlayer.Team then
Disable(HumanoidRootPart)__DARKLUA_CONTINUE_124=true
break
end

local Humanoid=Character:FindFirstChild"Humanoid"

if not Humanoid then
Disable(HumanoidRootPart)__DARKLUA_CONTINUE_124=true
break
end

if Humanoid.Health<=0 then
Disable(HumanoidRootPart)__DARKLUA_CONTINUE_124=true
break
end

if Humanoid.MaxHealth>100 then
Disable(HumanoidRootPart)__DARKLUA_CONTINUE_124=true
break
end

Capture(HumanoidRootPart)
HumanoidRootPart.Color=HitboxExtender.Config.Color
HumanoidRootPart.Material=HitboxExtender.Config.Material
HumanoidRootPart.Transparency=getgenv().Options and getgenv().Options.HitboxExtenderColor and getgenv().Options.HitboxExtenderColor.Transparency or HitboxExtender.Config.Transparency
HumanoidRootPart.Size=Vector3.new(2,2,2)*HitboxExtender.Config.SizeIncrease __DARKLUA_CONTINUE_124=true until true if not __DARKLUA_CONTINUE_124 then break end
end
end)

return HitboxExtender end function init.w()local v=init.cache.w if not v then v={c=__modImpl()}init.cache.w=v end return v.c end end do local __modImpl=function()
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
for index=#Tracers.Segments,1,-1 do local __DARKLUA_CONTINUE_128=false repeat
local segment=Tracers.Segments[index]
if segment.Expires<=now then Remove(index)__DARKLUA_CONTINUE_128=true break end
local line=segment.Line
if not camera then line.Visible=false __DARKLUA_CONTINUE_128=true break end
local a,aVisible=camera:WorldToViewportPoint(segment.From)
local b,bVisible=camera:WorldToViewportPoint(segment.To)
line.Visible=aVisible and bVisible
if line.Visible then
line.From=Vector2.new(a.X,a.Y)
line.To=Vector2.new(b.X,b.Y)
line.Transparency=math.clamp((segment.Expires-now)/0.15,0,1)
end __DARKLUA_CONTINUE_128=true until true if not __DARKLUA_CONTINUE_128 then break end
end
end

Runtime.Add(Tracers.Clear)
return Tracers end function init.x()local v=init.cache.x if not v then v={c=__modImpl()}init.cache.x=v end return v.c end end do local __modImpl=function()

local Core,
BulletTracers=init.t(),init.x()

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

for i=1,#Players do local __DARKLUA_CONTINUE_129=false repeat
local Player=Players[i]

if Player==LocalPlayer then __DARKLUA_CONTINUE_129=true
break
end

if Player.Team==LocalPlayer.Team then __DARKLUA_CONTINUE_129=true
break
end

local Character=Player.Character

if not Character then __DARKLUA_CONTINUE_129=true
break
end

local MaxDistance,CharacterDistance=
SilentAim.Config.Distance^2,Camera.CFrame.Position-Player.Character:GetPivot().Position
if CharacterDistance:Dot(CharacterDistance)>MaxDistance then __DARKLUA_CONTINUE_129=true
break
end

local Humanoid=Character:FindFirstChild"Humanoid"

if not Humanoid then __DARKLUA_CONTINUE_129=true
break
end

if Humanoid.Health<=0 then __DARKLUA_CONTINUE_129=true
break
end

if Humanoid.MaxHealth>100 then __DARKLUA_CONTINUE_129=true
break
end

local TargetPart=Character:FindFirstChild(SilentAim.Config.Hitpart)

if not TargetPart then __DARKLUA_CONTINUE_129=true
break
end

local ViewportPoint,OnScreen=Camera:WorldToViewportPoint(TargetPart.Position)

if not OnScreen then __DARKLUA_CONTINUE_129=true
break
end

local Vector=Vector2.new(ViewportPoint.X,ViewportPoint.Y)
local DistanceToMouse=(UserInputService:GetMouseLocation()-Vector).Magnitude

if DistanceToMouse>Distance then __DARKLUA_CONTINUE_129=true
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
end __DARKLUA_CONTINUE_129=true until true if not __DARKLUA_CONTINUE_129 then break end
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
for i=1,#GarbageCollection do local __DARKLUA_CONTINUE_130=false repeat
local v=GarbageCollection[i]

if typeof(v)~="function"then __DARKLUA_CONTINUE_130=true
break
end

local info=debug.getinfo(v)

if not info or typeof(info.source)~="string"or typeof(info.name)~="string"then __DARKLUA_CONTINUE_130=true
break
end

if info.source=="WeaponsProjectilesClient"and info.name=="simulateFirearmProjectile"then
return v
end __DARKLUA_CONTINUE_130=true until true if not __DARKLUA_CONTINUE_130 then break end
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

return SilentAim end function init.y()local v=init.cache.y if not v then v={c=__modImpl()}init.cache.y=v end return v.c end end do local __modImpl=function()

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

local Core=init.t()
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

for i=1,#Players do local __DARKLUA_CONTINUE_132=false repeat
local Player=Players[i]

if Player==LocalPlayer then __DARKLUA_CONTINUE_132=true
break
end

if Player.Team==LocalPlayer.Team then __DARKLUA_CONTINUE_132=true
break
end

local Character=Player.Character

if not Character then __DARKLUA_CONTINUE_132=true
break
end

local PrimaryPart=Character:FindFirstChild"HumanoidRootPart"

if not PrimaryPart then __DARKLUA_CONTINUE_132=true
break
end

local Humanoid=Character:FindFirstChild"Humanoid"

if not Humanoid then __DARKLUA_CONTINUE_132=true
break
end

if Humanoid.Health<=0 then __DARKLUA_CONTINUE_132=true
break
end

if Humanoid.MaxHealth>100 then __DARKLUA_CONTINUE_132=true
break
end

local Magnitude=(PrimaryPart.Position-StatesHrpClient.getHrp().Position).Magnitude

if Distance>Magnitude then
table.insert(Closest,{Player=Player,Health=Humanoid.Health})
end __DARKLUA_CONTINUE_132=true until true if not __DARKLUA_CONTINUE_132 then break end
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

for i=1,#Players do local __DARKLUA_CONTINUE_142=false repeat
local Player=Players[i]

if Enemy~=Player then __DARKLUA_CONTINUE_142=true
break
end

if not(Player.Character and Player.Character.PrimaryPart and LocalPlayer.Character and LocalPlayer.Character.PrimaryPart and Melee.TargetLines[Player])then __DARKLUA_CONTINUE_142=true break end
local To,OnScreen=Camera:WorldToViewportPoint(Player.Character.PrimaryPart.Position)
local To2,OnScreen2=Camera:WorldToViewportPoint(LocalPlayer.Character.PrimaryPart.Position)

if OnScreen and OnScreen2 then
Melee.TargetLines[Player].Visible=true
Melee.TargetLines[Player].Color=Melee.Config.ShowAuraTargetColor
Melee.TargetLines[Player].From=Vector2.new(To2.X,To2.Y)
Melee.TargetLines[Player].To=Vector2.new(To.X,To.Y)
else
Melee.TargetLines[Player].Visible=false
end __DARKLUA_CONTINUE_142=true until true if not __DARKLUA_CONTINUE_142 then break end
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

return Melee end function init.z()local v=init.cache.z if not v then v={c=__modImpl()}init.cache.z=v end return v.c end end do local __modImpl=function()

return{
HitboxExtender=init.w(),
SilentAim=init.y(),
MeleeAura=init.z(),
}end function init.A()local v=init.cache.A if not v then v={c=__modImpl()}init.cache.A=v end return v.c end end do local __modImpl=function()
local Core=init.t()local

Utils, 
Modules, 
Services, 
Variables=Core.Utils, Core.Modules, Core.Services, Core.Variables

local Players=Services.Players
local LocalPlayer,

FlagRig,

Flag,








Runtime,
ActivePrompts=Players.LocalPlayer,Modules:GetModule("FlagRig",true),{Config={InstantCapture=false,PickupSpeed=100,InstantRespawn=false,NoSpawnConditions=false,},},init.b(),setmetatable({},{__mode="k"})
local OldPromptTriggered,
OldPromptBegan,RestorePrompt=FlagRig.PromptTriggered,FlagRig.PromptBegan,function(

self)
local original=ActivePrompts[self]
if original then
if self.prompt then self.prompt.HoldDuration=original.prompt end
self.holdDuration=original.rig
ActivePrompts[self]=nil
end end


FlagRig.PromptTriggered=function(self)
local result=OldPromptTriggered(self)
RestorePrompt(self)
return result
end

FlagRig.PromptBegan=function(self)
RestorePrompt(self)
if Flag.Config.InstantCapture and not LocalPlayer:GetAttribute"FlagBearer"then
local speed=tonumber(Flag.Config.PickupSpeed)or 1
if speed~=speed then speed=1 end
speed=math.clamp(speed,1,100)
local original={prompt=self.prompt.HoldDuration,rig=self.holdDuration}
ActivePrompts[self]=original
local duration=original.prompt*(100-speed)/99
self.prompt.HoldDuration=duration
self.holdDuration=duration
OldPromptBegan(self)
if duration==0 then return FlagRig.PromptTriggered(self)end
return
end
return OldPromptBegan(self)
end

Flag.Update=LPH_JIT_MAX(function()
if not Flag.Config.InstantCapture then
for rig in pairs(ActivePrompts)do RestorePrompt(rig)end
end
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
end)

Runtime.Add(function()
FlagRig.PromptBegan=OldPromptBegan
FlagRig.PromptTriggered=OldPromptTriggered
for rig in pairs(ActivePrompts)do RestorePrompt(rig)end
end)
return Flag end function init.B()local v=init.cache.B if not v then v={c=__modImpl()}init.cache.B=v end return v.c end end do local __modImpl=function()

local Core,
Network=init.t(),init.v()

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

return Godmode end function init.C()local v=init.cache.C if not v then v={c=__modImpl()}init.cache.C=v end return v.c end end do local __modImpl=function()

local Mods,





















Core={Shooting={NoRecoil=false,NoSpread=false,NoMisfires=false,InstantAim=false,IgnoreReloadPenalties=false,},Melee={SetDamage=false,SetDamageAmount=1,},Misc={CavInfStamina=false,NoMoralLossFromShots=false,RemoveMoraleCameraShake=false,NoMoralLossFromCannonFire=false,},},init.t()


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

return Mods end function init.D()local v=init.cache.D if not v then v={c=__modImpl()}init.cache.D=v end return v.c end end do local __modImpl=function()

local Core,
Network=init.t(),init.v()

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

return Chants end function init.E()local v=init.cache.E if not v then v={c=__modImpl()}init.cache.E=v end return v.c end end do local __modImpl=function()
local Services=init.t().Services
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

return Movement end function init.F()local v=init.cache.F if not v then v={c=__modImpl()}init.cache.F=v end return v.c end end do local __modImpl=function()
return{
FlagMods=init.B(),
Godmode=init.C(),
WeaponMods=init.D(),
Chants=init.E(),
Movement=init.F(),
}end function init.G()local v=init.cache.G if not v then v={c=__modImpl()}init.cache.G=v end return v.c end end do local __modImpl=function()
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

return Owner end function init.H()local v=init.cache.H if not v then v={c=__modImpl()}init.cache.H=v end return v.c end end do local __modImpl=function()

local Core=init.t()
local Lighting,
HttpService,
Owner=Core.Services.Lighting,Core.Services.HttpService,init.H().new()
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
return World end function init.I()local v=init.cache.I if not v then v={c=__modImpl()}init.cache.I=v end return v.c end end do local __modImpl=function()

return{
World=init.I(),
BulletTracers=init.x(),
}end function init.J()local v=init.cache.J if not v then v={c=__modImpl()}init.cache.J=v end return v.c end end do local __modImpl=function()
return{
Combat=init.A(),
Misc=init.G(),
Visuals=init.J()
}end function init.K()local v=init.cache.K if not v then v={c=__modImpl()}init.cache.K=v end return v.c end end do local __modImpl=function()
return{
Core=init.t(),
Network=init.v(),
Utils=init.r(),
Features=init.K(),
}end function init.L()local v=init.cache.L if not v then v={c=__modImpl()}init.cache.L=v end return v.c end end do local __modImpl=function()



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
'{"FontColor":"e6eaf5","MainColor":"171b25","AccentColor":"7c8cff","BackgroundColor":"0e1118","OutlineColor":"2b3243"}'
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

return ThemeManager end function init.M()local v=init.cache.M if not v then v={c=__modImpl()}init.cache.M=v end return v.c end end do local __modImpl=function()

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
local Panels=init.l()
if not ready then
baseLibrary.StandardCursor=true
local window,
manager=baseLibrary:CreateWindow{Title="NW Private — readiness",Center=true,AutoShow=true},init.m()
manager:SetLibrary(baseLibrary)
manager:SetFolder"84e Client/NW"
Panels.Build(baseLibrary,window,manager,{})
return nil
end
local checkpoint,
initialized,modules=Runtime.Checkpoint(),pcall(function()return init.L()end)
if not initialized then
Runtime.Record("initialization",modules)
Runtime.Rollback(checkpoint)
baseLibrary.StandardCursor=true
local window,
manager=baseLibrary:CreateWindow{Title="NW Private — integration unavailable",Center=true,AutoShow=true},init.m()
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

Window=init.M(),init.m(),Library:CreateWindow{
Title="NW Private",
Subtitle=Preflight.Version,
Size=UDim2.fromOffset(920,660),
Center=true,
AutoShow=true,
TabPadding=4,
MenuFadeTime=0.2,
}

local Tabs,





SettingsRoot={Legit=Window:AddTab"Legit",Rage=Window:AddTab"Rage",Visuals=Window:AddTab"Visuals",Misc=Window:AddTab"Misc",},Window:AddTab"Settings"
SettingsRoot:SetLayoutOrder(5)
local SettingsPages={
General=SettingsRoot:AddPage"General",
Appearance=SettingsRoot:AddPage"Appearance",
Profiles=SettingsRoot:AddPage"Profiles",
Diagnostics=SettingsRoot:AddPage"Diagnostics",
}
Tabs.Settings=SettingsPages.General

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
WorldSection=init.I(),Tabs.Visuals:AddLeftGroupbox"World"

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
BulletTracerSection=init.x(),Tabs.Visuals:AddRightGroupbox"Weapon Visuals"

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

TabBox=init.D(),init.B(),Tabs.Misc:AddRightTabbox"Mods"

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
Text="Fast Flag Pickup",
Default=false,
Callback=function(Value)
FlagMods.Config.InstantCapture=Value
end,
})

FlagModsTab:AddSlider("FlagPickupSpeed",{
Text="Pickup Speed",Default=100,Min=1,Max=100,
Rounding=0,Suffix="%",Compact=false,
Tooltip="1% uses normal hold time. 100% is instant. Applies when Fast Flag Pickup is enabled.",
Callback=function(Value)FlagMods.Config.PickupSpeed=Value end,
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
CharacterSection=init.C(),Tabs.Misc:AddRightGroupbox"Character"

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

local Movement=init.F()

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
Library:Notify("NW Private "..Preflight.Version.." | error categories: "..tostring(#Runtime.ErrorOrder).." | recorded failures: "..tostring(failures))
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
ThemeManager:ApplyToTab(SettingsPages.Appearance)

SaveManager:SetLibrary(Library)
SaveManager:SetFolder"84e Client/NW"
SaveManager:IgnoreThemeSettings()
SaveManager:BuildConfigSection(SettingsPages.Profiles)
local world=modules.Features.Visuals.World
Panels.Build(Library,Window,SaveManager,{
SettingsPages=SettingsPages,World=world,Tracers=modules.Features.Visuals.BulletTracers,ThemeManager=ThemeManager,
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

Library:SetWatermark("NW Private - "
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

return nil end function init.N()local v=init.cache.N if not v then v={c=__modImpl()}init.cache.N=v end return v.c end end end


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
local initialized,initError=pcall(function()init.N()end)
if not initialized then
local session=getgenv().Client84eSession
if session and session.Stop then pcall(session.Stop)end
warn("84e initialization failed: "..tostring(initError))
end
end