
currenttab = undefined;

function switchtab(tab) {
	if (currenttab != tab)
		console.log("switched tab to "+tab);
	currenttab = tab;
}

function inspect(obj){
	console.log(obj);
	for(var i in obj){
		if(typeof(obj[i]) == "function"){
			console.log("  " + i + ": function()");
		}
		else{
			console.log("  " + i + ": " + obj[i])
		}
	}
}

function goober(){
	console.log('goober');
}

var agentsSkillRefreshHandle = dojo.subscribe("skills/init", function(data){
	var node = dijit.byId('agentSkills').domNode;
	while(node.hasChildNodes()){
		node.removeChild(node.lastChild);
	}
	skills.skillSelection(dijit.byId("agentSkills").domNode);
	
	var brandoptgroup = dojo.doc.createElement('optgroup');
	brandoptgroup.label = '_brand';
	var setBrandSkills = function(items){
		for(var i in items){
			var opt = dojo.doc.createElement('option');
			opt.value = "{_brand," + items[i] + "}";
			opt.innerHTML = items[i];
			brandoptgroup.appendChild(opt);
		}
		dijit.byId("agentSkills").domNode.appendChild(brandoptgroup);
	}
	
	skills.expandSkill(setBrandSkills, "_brand");

	var queueOptGroup = dojo.doc.createElement('optgroup');
	queueOptGroup.label = '_queue';
	var setQueueSkills = function(items){
		for(var i in items){
			var opt = dojo.doc.createElement('option');
			opt.value = "{_queue," + items[i] + "}";
			opt.innerHTML = items[i];
			queueOptGroup.appendChild(opt);
		}
		dijit.byId("agentSkills").domNode.appendChild(queueOptGroup);
	}
	skills.expandSkill(setQueueSkills, "_queue");
											  
});

var agentsTreeRefreshHandle = dojo.subscribe("agents/tree/refreshed", function(data){
	dijit.byId('agentProfile').store = agents.store;
	dojo.connect(agents.tree, "onClick", function(item){
		if(item.type[0] == "profile"){
			dijit.byId("agentProfileSubmit").onClick = function(){
				agents.updateProfile('editAgentProfileForm', 'agentsList');
			};
			dojo.byId("agentProfileOldName").value = item.name[0];
			dijit.byId("agentProfileName").attr("value", item.name[0]);
			if(item.name[0] == "Default"){
				dijit.byId("agentProfileName").setDisabled(true);
			}
			else{
				dijit.byId("agentProfileName").setDisabled(false);
			}
			dijit.byId('agentsMain').selectChild('agentProfileEditor');
			var node = dijit.byId("agentProfileSkills").domNode;
			while(node.hasChildNodes()){
				node.removeChild(node.lastChild);
			}
				 
			var setSkills = function(groups, profileSkills){
				console.log(groups);
				
				skills.skillSelection(dijit.byId("agentProfileSkills").domNode);
				dojo.xhrGet({
					url:"/agents/profiles/" + item.name[0] + "/getskills",
					handleAs:"json",
					load:function(resp, ioargs){
						var atomMatch = function(needle){
							for(var i in resp.items){
								if( (! resp.items[i].expanded) && resp.items[i].atom == needle){
									return true;
								}
							};
							return false;
						}
						var expandedMatch = function(atom, expanded){
							for(var i in resp.items){
								if(resp.items[i].atom == atom){
									if(resp.items[i].expanded == expanded){
										return true;
									}
								}
							}
							return false;
						}
						var reserved = {
							"_queue":true,
							"_agent":true,
							"_node":true,
							"_brand":true
						};
						var sel = dijit.byId("agentProfileSkills").domNode;
						for(var i in sel.childNodes){
							var selkid = sel.childNodes[i];
							for(var j in selkid.childNodes){
								var node = selkid.childNodes[j];
								if(! reserved[node.value]){
									if(atomMatch(node.value)){
										node.selected = true;
									}
									else{
										node.selected = false;
									}
								}
								else{
									node.disabled = true;
								}
							}
						}
						
						var brandoptgroup = dojo.doc.createElement('optgroup');
						brandoptgroup.label = '_brand';
						var setBrandSkills = function(items){
							for(var i in items){
								var opt = dojo.doc.createElement('option');
								opt.value = "{_brand," + items[i] + "}";
								opt.innerHTML = items[i];
								opt.selected = expandedMatch("_brand", items[i]);
								brandoptgroup.appendChild(opt);
							}
						}
						dijit.byId("agentProfileSkills").domNode.appendChild(brandoptgroup);
						skills.expandSkill(setBrandSkills, "_brand");
						
						var queueOptGroup = dojo.doc.createElement('optgroup');
						queueOptGroup.label = '_queue';
						var setQueueSkills = function(items){
							for(var i in items){
								var opt = dojo.doc.createElement('option');
								opt.value = "{_queue," + items[i] + "}";
								opt.innerHTML = items[i];
								opt.selected = expandedMatch("_queue", items[i]);
								queueOptGroup.appendChild(opt);
							}
						}
						dijit.byId("agentProfileSkills").domNode.appendChild(queueOptGroup);
						skills.expandSkill(setQueueSkills, "_queue");
					}
				});
				
			};
			
			skills.store.fetch({
				query:{type:"group"},
				onComplete:setSkills
			});
			
			dijit.byId("agentsDestroyButton").onClick = function(){
				dojo.xhrGet({
					url:"agents/profiles/" + item.name[0] + "/delete",
					handleAs:"json",
					load:function(response, ioargs){
						if( ! response.success){
							console.log(response.message);
						}
						else{
							agents.refreshTree('agentsList');
						}
					}
				})
			}
		}
		else{
			dojo.xhrGet({
				url:"/agents/agents/" + item.name[0] + "/get",
				handleAs:"json",
				load:function(response, ioargs){
					var agent = response.agent;
					dijit.byId("agentLogin").attr("value", agent.login);
					dojo.byId("agentOldLogin").value = agent.login;
					//dijit.byId("agentProfile").attr("value", agent.profile);
					dojo.byId("agentIntegrated").innerHTML = agent.integrated;
					dijit.byId("agentSecurity").setValue(agent.securitylevel);
					dijit.byId("agentProfile").setDisplayedValue(agent.profile);
					
					var selectSkill = function(skill){
						if(/\{\w+\,\w+\}/.test(skill)){
							var split = skill.split(',');
							var atom = split[0].substr(1);
							var expanded = split[1].substr(0, split[1].length-1);
							for(var i in agent.skills){
								if(agent.skills[i].atom == atom && agent.skills[i].expanded == expanded){
									return true;
								}
							}
							return false;
						}
						else{
							for(var i in agent.skills){
								if(agent.skills[i].atom == skill){
									return true;
								}
								return false
							}
						}
					}
					
					var sel = dijit.byId("agentSkills").domNode;
					for(var i in sel.childNodes){
						if(sel.childNodes[i].hasChildNodes){
							var kid = sel.childNodes[i];
							var label = sel.label;
							for(var j in kid.childNodes){
								var kidkid = kid.childNodes[j];
								if(kidkid.nodeType == 1){
									if(selectSkill(kidkid.value)){
										kidkid.selected = true;
									}
									else{
										kidkid.selected = false;
									}
								}
							}
						}
					}
					
					
					
/*

 </p>
 <p>
 <label for="agentProfile">Profile:</label>
 <select dojoType="dijit.form.FilteringSelect" id="agentProfile" name="profile"></select>
 </p>
 <p>
 <label for="agentSkills">Skills:</label>
 <div id="agentSkills">
 <select dojoType="dijit.form.MultiSelect" id="agentSkills" name="skills" size="10" multiple="true"></select>
 </div>
 </p>
 <p>
 <label for="agentSubmit">&nbsp;</label>
 <button dojoType="dijit.form.Button" label="Submit" id="agentSubmit" onClick="agents.updateAgent('editAgent', 'agentsList')"></button>
 </p>
 </form>
 </div>*/					console.log(response);
				}
			});
		
			dijit.byId('agentsMain').selectChild('agentEditor');
			dijit.byId('agentsDestroyButton').onClick = function(){
				dojo.xhrGet({
					url:"agents/agents/" + item.name[0] + "/delete",
					handleAs:"json",
					load:function(response, ioargs){
						if(response.success){
							agents.refreshTree('agentsList');
						}
						else{
							console.log(response.message);
						}
					}
				});
			}
		}
	});
});

dojo.addOnLoad(function(){
	var loginform = dijit.byId("loginform")
	dojo.connect(loginform, "onSubmit", function(e){
		e.preventDefault();
		if (loginform.isValid()){
			dojo.xhrGet({
				url:"/getsalt",
				handleAs:"json",
				error:function(response, ioargs){
					dojo.byId("loginerrp").style.display = "block";
					dojo.byId("loginerrspan").innerHTML = response.responseText;
				},
				load:function(response, ioargs){
					salt = response.salt;
					attrs = loginform.attr("value");
					md5pass = dojox.encoding.digests.MD5(attrs.password, dojox.encoding.digests.outputTypes.Hex);
					salted = dojox.encoding.digests.MD5(salt + md5pass, dojox.encoding.digests.outputTypes.Hex);
					values = attrs;
					values.password = salted;
					dojo.xhrPost({
						url:"/login",
						handleAs:"json",
						content:values,
						load:function(response2, ioargs2){
							if(response2.success){
								dijit.byId("loginpane").hide();
								dojo.byId("main").style.display="block";
								dojo.byId("main").style.visibility = "visible";
								agents.init();
								agents.refreshTree("agentsList");
							}
							else{
								dojo.byId("loginerrp").style.display = "block";
								dojo.byId("loginerrspan").innerHTML = response2.message;
							}
						}
					});
				}
			});
		}
	});

//	var theForm = dijit.byId("editSkillPane");
	// another dojo.connect syntax: call a function directly	
//	dojo.connect(theForm,"onsubmit",setSkill);
	
	dojo.xhrGet({
		url:"/checkcookie",
		handleAs:"json",
		error:function(response, ioargs){
			console.log("checkcookie failed!");
			console.log(response);
		},
		load:function(response, ioargs){
			if(response.success){
				dojo.byId("main").style.display="block";
				dojo.byId("main").style.visibility = "visible";
				agents.init();
				agents.refreshTree("agentsList");
				skills.init();
				//skills.skillSelection(dijit.byId('agentNewProfileSkills').domNode);
			}
			else{
				dijit.byId("loginpane").show();
			}
		}
	});
});

