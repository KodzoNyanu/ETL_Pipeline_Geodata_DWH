page 50100 "ETL Shipment Headers API"
{
    PageType = API;
    APIPublisher = 'etlpipeline';
    APIGroup = 'warehouse';
    APIVersion = 'v1.0';
    EntityName = 'etlShipmentHeader';
    EntitySetName = 'etlShipmentHeaders';
    SourceTable = "ETL Shipment Header";
    DelayedInsert = true;
    ODataKeyFields = "Header Id";

    layout
    {
        area(Content)
        {
            repeater(GroupName)
            {
                field(headerId; Rec."Header Id") { Caption = 'headerId'; }
                field(customerNo; Rec."Customer No") { Caption = 'customerNo'; }
                field(orderNo; Rec."Order No") { Caption = 'orderNo'; }
                field(shipmentDate; Rec."Shipment Date") { Caption = 'shipmentDate'; }
                field(shipToCity; Rec."Ship To City") { Caption = 'shipToCity'; }
                field(shipToCountry; Rec."Ship To Country") { Caption = 'shipToCountry'; }
                field(etlLoadedAt; Rec."ETL Loaded At") { Caption = 'etlLoadedAt'; }
            }
        }
    }
}
