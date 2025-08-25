'use strict';

const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB({ apiVersion: '2012-08-10', region: process.env.REGION || 'us-east-1' });
const TABLE = process.env.DDB_COUNTERS_TABLE;

exports.handler = async (event, context, callback) => {
  try {
    const cf = event.Records[0].cf;
    const response = cf.response;
    const uri = cf.request.uri || '';
    // Expect /images/{id}/{size}.jpg or similar
    const parts = uri.split('/').filter(Boolean);
    let imageId = null, size = null;
    if (parts.length >= 3 && parts[0] === 'images') {
      imageId = parts[1];
      const file = parts[2];
      size = file.split('.')[0]; // "thumb" from "thumb.jpg"
    }
    const headers = response.headers;

    if (imageId && size) {
      headers['x-image-id'] = [{ key: 'x-image-id', value: imageId }];
      headers['x-image-size'] = [{ key: 'x-image-size', value: size }];
      try {
        const res = await ddb.getItem({
          TableName: TABLE,
          Key: { imageId: { S: imageId }, size: { S: size } },
          ConsistentRead: false
        }).promise();
        if (res && res.Item) {
          const views = res.Item.views ? res.Item.views.N : '0';
          const pixels = res.Item.pixelsViewed ? res.Item.pixelsViewed.N : '0';
          headers['x-views'] = [{ key: 'x-views', value: String(views) }];
          headers['x-pixels-viewed'] = [{ key: 'x-pixels-viewed', value: String(pixels) }];
        }
      } catch (e) {
        // don't fail the response on counter read errors
      }
    }

    return callback(null, response);
  } catch (err) {
    return callback(null, event.Records[0].cf.response);
  }
};
