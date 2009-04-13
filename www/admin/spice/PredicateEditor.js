dojo.provide("spice.PredicateEditorRow");
dojo.provide("spice.PredicateEditor");

dojo.declare("PredicateEditorRow", [dijit._Widget, dijit._Templated], {
	templatePath: dojo.moduleUrl("spice","PredicateEditorRow.html"),
	widgetsInTemplate: true,
	templateString: "",
	store:[],
	propwidth:"20em",
	compwidth:"10em",
	valwidth:"20em",
	setComparisons: function(prop){
		var ithis = this;
		var callback = function(res, req){
			var items = [];
			if(! res[0]){
				return;
			}
			for(var i in res[0].comparisons){
				items.push({
					'label':res[0].comparisons[i].label[0],
					'value':res[0].comparisons[i].value[0]});
			};
			ithis.comparisonField.store = new dojo.data.ItemFileReadStore({
				data:{
					identifier:"value",
					label:"label",
					"items":items
				}
			});
			ithis.valueField.regExp = res[0].regExp[0]
		}
		this.propertyField.store.fetch({
			query:{'value':prop},
			onComplete:callback
		});
	},
	getValue: function(){
		out = {
			"property":this.propertyField.value,
			"comparison":this.comparisonField.value,
			"value":this.valueField.value
		};
		return out;
	},
	setValue: function(obj){
		this.propertyField.setValue(obj.property);
		this.comparisonField.setValue(obj.comparison);
		this.valueField.setValue(obj.value);
	}
});

dojo.declare("PredicateEditor", [dijit._Widget, dijit._Templated], {
	templatePath: dojo.moduleUrl("spice", "PredicateEditor.html"),
	widgetsInTemplate:true,
	templateString:"",
	store:[],
	rows:[],
	propwidth:"20em",
	compwidth:"10em",
	valwidth:"20em",
	addRow:function(){
		var ithis = this;
		var row = new PredicateEditorRow({
			store: this.store,
			propwidth: this.propwidth,
			compwidth: this.compwidth,
			valwidth: this.valwidth
		});
		row.addButton.onClick = function(){
			ithis.addRow();
		};
		row.dropButton.onClick = function(){
			ithis.dropRow(row.id);
		};
		this.rows.push(row.id);
		this.topNode.appendChild(row.domNode);
	},
	dropRow:function(rowid){
		if(this.rows.length < 2){
			return;
		}
		dijit.byId(rowid).destroy();
		var newrows = [];
		for(var i in this.rows){
			if(this.rows[i] != rowid){
				newrows.push(this.rows[i]);
			}
		}
		this.rows = newrows;
	},
	getValue:function(){
		var items = [];
		for(var i in this.rows){
			items.push(dijit.byId(this.rows[i]).getValue());
		}
		return items;
	},
	setValue:function(list){
		for(var i in this.rows){
			try{
				dijit.byId(this.rows[i]).destroy();
			}
			catch(err){
				//Do nothing w/ the error, just ignore it.
			}
		}
		this.rows = [];
		for(var i in list){
			this.addRow();
			dijit.byId(this.rows[i]).setValue(list[i]);
		}
	},
	postCreate:function(){
		this.addRow();
	}
});