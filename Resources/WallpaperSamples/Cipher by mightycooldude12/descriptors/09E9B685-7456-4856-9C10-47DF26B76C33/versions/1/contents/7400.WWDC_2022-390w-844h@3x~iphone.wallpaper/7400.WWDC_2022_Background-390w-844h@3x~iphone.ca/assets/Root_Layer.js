'use strict';

/*
 Built-in variables (don't uncomment, for documentation only).

 var layer;		  -- this script's layer
 var document;	-- this script's document
 var system;    -- Properties about the current system. Local to each context
                   (version, build, productType, model, platform, appVersion)
 var instance;  -- ScriptObject (Properties: inspector)

 Script initialization functions:
 
   init(): Initialize variables and state. This will be called when a script is loaded
           or updated. Do not depend on the ordering. Do not assume that all other scripts
           have been initialized.

   ready(): Called after all scripts are initialized. If a single script is updated,
            only that script will have ready() called. Do not depend on the ordering.
 
 'Strict' mode is on by default:
   https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Strict_mode
 */

// function init() {
// }

// function ready() {
// }

// function eventHandler(event) {
// }

// function layoutSublayers() {
// }

// Called on display refresh. Use 'link.duration' for time passed since the previous frame.
// function updateForDisplay(link) {
// }

// function signalHandler(signalName) {
// }

// function drawLayer(ctx) {
// }

// ------------
// Inspector UI
// ------------

// (Optional) Declares a specially named JS variable for the title of the inspector tab.
// var inspectorTabTitle = "My Title";


/* (Optional for modules) Declares a function to update the UI. The return value should be an array
   of InspectorItem objects. See InspectorItem for details. Use the instance.inspector.reloadView()
   to have this function called when the UI should be updated.
   * inspector - The inspector view shown in the sidebar
   * proposedInspectorItems - A list of items (if any) the inspector will use by default.
                              You can modify and return any or none of the items. */

// function updateInspectorView(inspector, proposedInspectorItems) {
// }


// (Optional) Declares a property getting function that returns a value for a key
// * key - The key for the value to return

// function getPropertyValue(key) {
// }


// (Optional) Declares a property setting function that stores the value for the key
// * key - The key for the value to set
// * value - The new value for the property named 'key'

// function setPropertyValue(key, value) {
// }


// (Optional) Declares a function to be notified after a property value has changed in the inspector.
// * key - The key for the value that changed.

// function propertyValueChanged(key) {
// }

// ----------------
// Property Storage
// ----------------

// If you use the default storage for your properties, you can access them using:
//       `instance.properties.<propertyName>`
// This works for both standalone scrips and module scripts.


// (Optional) Declare a `properties` object to provide a custom place to store the values for your script.

// let properties = {
//   "myValue": 10
// };


// (Optional) Declares a function to initialize your stored properties when the document is reopened or the script is reinitialized
// * key - The name of the property
// * value - The property value associated with the name `key`

// function initializePropertyValue(key, value) {
//   properties[key] = value;
// }


// (Optional) Declares a function to store properties when the document is saved.
// * storage - The ScriptStorage object that will persist its values when the document is saved.

// function storePropertyValues(storage) {
//   for (const [key, value] of Object.entries(properties)) {
//     storage.setItem(key, value)
//   }
// }
